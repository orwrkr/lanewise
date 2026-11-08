#!/usr/bin/env python3
"""A size budget for what the plugin puts into a session (and what `orch` prints into one).

    check_sizes.py [--root DIR]            the repository's files (the self-test and CI run this)
    check_sizes.py --output NAME < TEXT    the text on stdin, measured against the budget named NAME

Tokens are estimated as characters / 4, rounded up. Exit 0 within every budget, 1 when one is over (the message says
what to do), 2 on a usage error or an unreadable file. A line is printed for every budget; a budget at 85% or more
gets a warning line as well, so the growth shows before it fails.

Raising a budget is a decision: say why in the commit message. The comment after each number is the size measured
when the budget was set. The budget is that size plus 15 to 20%, rounded: a margin of less than 18% would
warn from the first run (the warning starts at 85%).
"""
import argparse
import re
import sys
from pathlib import Path

# Budgets in tokens.
BUDGETS = {
    # the frontmatter `description` of every agent, skill and command: Claude Code lists them in every session
    "always-on descriptions": 900,          # measured 722 tokens
    "skills/orchestrate/SKILL.md": 3700,    # measured 3076 tokens
    "agents/orch-*.md": 300,                # one budget for each file; the largest measured 252 tokens
    "AGENTS.md + CLAUDE.md": 2800,          # measured 2329 tokens (raised from 2600 when the process rules moved here)
}
# Output that `orch` prints into a session; the self-test pipes it in with `--output NAME`.
OUTPUT_BUDGETS = {
    "registry-brief": 1950,                 # `orch registry show`, the built-in registry: measured 1631 tokens
    "session-start": 550,                   # `orch hook session-start` in the suite's used home: measured 429 tokens
}
WARN_AT = 0.85
OVER = ("%s: %d tokens, over its budget of %d: move rarely needed text to skills/orchestrate/reference/ (orch guide), "
        "or raise the budget in tests/check_sizes.py and say why in the commit message")


class Unreadable(Exception):
    pass


def tokens(text):
    return -(-len(text) // 4)


def read(path):
    try:
        return path.read_bytes().decode("utf-8").replace("\r\n", "\n")
    except (OSError, UnicodeDecodeError) as e:
        raise Unreadable("%s: cannot read: %s" % (path, e))


def description(text):
    """The frontmatter `description` of a markdown file: one line, or a `>` / `|` block."""
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return ""
    lines = m.group(1).split("\n")
    for i, line in enumerate(lines):
        if line.startswith("description:"):
            rest = line[len("description:"):].strip()
            if re.match(r"^[>|][+-]?$", rest):
                block = []
                for nxt in lines[i + 1:]:
                    if nxt.strip() and not nxt[0].isspace():
                        break
                    block.append(nxt.strip())
                return " ".join(b for b in block if b)
            if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in "'\"":
                rest = rest[1:-1]
            return rest
    return ""


def repository_sizes(root):
    """[(name, tokens, budget)] for the repository's budgeted files."""
    plugin = root / "plugins" / "orchestra"
    out = []
    total = 0
    for pattern in ("agents/*.md", "skills/*/SKILL.md", "commands/*.md"):
        for path in sorted(plugin.glob(pattern)):
            total += tokens(description(read(path)))
    out.append(("always-on descriptions", total, BUDGETS["always-on descriptions"]))
    skill = plugin / "skills" / "orchestrate" / "SKILL.md"
    out.append(("skills/orchestrate/SKILL.md", tokens(read(skill)), BUDGETS["skills/orchestrate/SKILL.md"]))
    agents = sorted(plugin.glob("agents/orch-*.md"))
    if not agents:
        raise Unreadable("%s: no agents/orch-*.md files" % plugin)
    for path in agents:
        out.append(("agents/" + path.name, tokens(read(path)), BUDGETS["agents/orch-*.md"]))
    both = read(root / "AGENTS.md") + read(root / "CLAUDE.md")
    out.append(("AGENTS.md + CLAUDE.md", tokens(both), BUDGETS["AGENTS.md + CLAUDE.md"]))
    return out


def report(rows):
    """Print one line per budget (and the warnings and the failures); the exit code."""
    failed = []
    for name, n, budget in rows:
        print("%s: %d / %d tokens" % (name, n, budget))
        if n > budget:
            failed.append(OVER % (name, n, budget))
        elif n >= WARN_AT * budget:
            print("warning: %s is at %d%% of its budget" % (name, round(100.0 * n / budget)))
    for message in failed:
        print(message, file=sys.stderr)
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser(description="A size budget for what the plugin puts into a session.")
    p.add_argument("--root", default=str(Path(__file__).resolve().parents[3]),
                   help="repository root (default: the one this script is in)")
    p.add_argument("--output", metavar="NAME", choices=sorted(OUTPUT_BUDGETS),
                   help="measure the text on stdin against the budget of this output: " + ", ".join(sorted(OUTPUT_BUDGETS)))
    a = p.parse_args()
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    try:
        if a.output:
            text = sys.stdin.buffer.read().decode("utf-8").replace("\r\n", "\n")
            rows = [(a.output, tokens(text), OUTPUT_BUDGETS[a.output])]
        else:
            rows = repository_sizes(Path(a.root))
    except (Unreadable, UnicodeDecodeError) as e:
        print("check_sizes: %s" % e, file=sys.stderr)
        return 2
    return report(rows)


if __name__ == "__main__":
    sys.exit(main())
