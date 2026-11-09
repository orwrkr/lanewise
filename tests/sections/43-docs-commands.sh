echo "── orch commands named in the docs exist"
# A session runs the `orch` commands the docs name: one the CLI no longer has makes it fail and retry. Every `orch …`
# inline span and fenced line in SKILL.md, its reference parts, the commands and the README is walked through
# build_parser() — the first token a subcommand, each nested subcommand down the tree, every --option an option of the
# parser reached at that point. Placeholders (<id>, N, PROVIDER=PROFILE), quoted text, values after options, the a|b
# alternatives (set|clear) and the `-- <claude args>` tail are understood; a command the rules cannot read should be
# rewritten in the doc, not special-cased here.
dc_out=$($PY -B - "$(native "$PLUGIN")" <<'EOF'
import argparse
import glob
import importlib.machinery
import importlib.util
import os
import re
import sys

plugin = sys.argv[1]

# Load bin/orch as a module, as 19-launcher-cache.sh does: build_parser() is the real one the CLI uses.
loader = importlib.machinery.SourceFileLoader("orch_docs_under_test", os.path.join(plugin, "bin", "orch"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch_docs_under_test", loader))
loader.exec_module(m)
root = m.build_parser()

docs = [os.path.join(plugin, "skills", "orchestrate", "SKILL.md"), os.path.join(plugin, "README.md")]
docs += sorted(glob.glob(os.path.join(plugin, "skills", "orchestrate", "reference", "*.md")))
docs += sorted(glob.glob(os.path.join(plugin, "commands", "*.md")))


def subparsers(p):
    for action in p._actions:
        if isinstance(action, argparse._SubParsersAction):
            return action
    return None


def takes_positionals(p):
    """True when the parser has positional arguments besides its nested subcommands."""
    return any(not a.option_strings and not isinstance(a, argparse._SubParsersAction) for a in p._actions)


def option_actions(p):
    out = {}
    for action in p._actions:
        for name in action.option_strings:
            out[name] = action
    return out


def value_count(action, tokens, start):
    """How many tokens after an option are its value: nargs=0 none, None one, '?' one unless it is an option."""
    nargs = action.nargs
    if nargs == 0:
        return 0
    if nargs is None:
        return 1 if start < len(tokens) else 0
    if isinstance(nargs, int):
        return nargs
    if nargs == "?":
        return 1 if start < len(tokens) and not tokens[start].startswith("-") else 0
    count = 0                               # '*' and '+': every following token that is not an option
    while start + count < len(tokens) and not tokens[start + count].startswith("-"):
        count += 1
    return count


def is_placeholder(token):
    """<id>, …, ..., N, ID, PROVIDER=PROFILE, DONE|BLOCKED|FAILED, AG-0004: not checked as a subcommand or option."""
    if token in ("…", "..."):
        return True
    if token.startswith("<") or token.endswith(">"):
        return True
    return bool(re.fullmatch(r"[A-Z0-9][A-Z0-9_=|\-]*", token))


def clean(token):
    return token.strip("[]()").rstrip(",.")


def check_hook(tokens, where):
    problems = []
    hook = subparsers(root).choices["hook"]
    actions = option_actions(hook)
    i = 0
    while i < len(tokens):
        token = clean(tokens[i])
        if not token:
            i += 1
        elif token == "--":
            break
        elif token.startswith("-"):
            name = token.split("=", 1)[0]
            if name not in actions:
                problems.append((where, tokens[i], "not an option of `%s`" % hook.prog))
                i += 1
            else:
                i += 1 + (0 if "=" in token else value_count(actions[name], tokens, i + 1))
        else:
            if not is_placeholder(token) and token not in m.HOOK_EVENTS:     # the events hook_args accepts
                problems.append((where, tokens[i], "not a hook event"))
            i += 1
    return problems


def check(command, where):
    """The bad (where, token, reason) triples of one `orch …` command."""
    tokens = command.split()
    if not tokens or tokens[0] != "orch":
        return []
    tokens = tokens[1:]
    if not tokens:
        return []
    first = clean(tokens[0])
    if first == "hook":
        return check_hook(tokens[1:], where)
    sub = subparsers(root)
    if sub is None or first not in sub.choices:
        return [(where, tokens[0], "not a subcommand")]
    parser = sub.choices[first]
    problems = []
    unknown = False                         # set once a placeholder stands where a subcommand would be
    i = 1
    while i < len(tokens):
        token = clean(tokens[i])
        if not token:
            i += 1
        elif token == "--":
            break                           # everything after -- goes to claude untouched
        elif token.startswith("-"):
            name = token.split("=", 1)[0]
            actions = option_actions(parser)
            if name not in actions:
                problems.append((where, tokens[i], "not an option of `%s`" % parser.prog))
                i += 1
            else:
                i += 1 + (0 if "=" in token else value_count(actions[name], tokens, i + 1))
        else:
            nested = subparsers(parser)
            target = None
            if nested is not None and not is_placeholder(token):
                for alt in (clean(a) for a in token.split("|")):
                    if alt in nested.choices:
                        target = nested.choices[alt]
                        break
            if target is not None:
                parser = target
            elif nested is not None and is_placeholder(token):
                unknown = True              # `orch profile … deepseek`: a placeholder stands for the subcommand
            elif nested is not None and not unknown and not takes_positionals(parser):
                # a parser with nested subcommands and no positional of its own: the word must be one of them
                problems.append((where, tokens[i], "not a subcommand of `%s`" % parser.prog))
                unknown = True              # report the first wrong word only, not the words after it
            i += 1                          # a subcommand, a positional value or a placeholder
    return problems


def inline_spans(start_line, text):
    """(line, content) of each `code span`; text may hold a span broken across lines."""
    spans = []
    pos = 0
    while True:
        begin = text.find("`", pos)
        if begin < 0:
            return spans
        end = text.find("`", begin + 1)
        if end < 0:
            return spans
        spans.append((start_line + text.count("\n", 0, begin), text[begin + 1:end]))
        pos = end + 1


def prepare(command):
    """Drop a shell comment and turn quoted text into a placeholder (`--task "<short>"`)."""
    command = re.split(r"\s+#", command, maxsplit=1)[0]
    command = re.sub(r'"[^"]*"', "_", command)
    command = re.sub(r"'[^']*'", "_", command)
    return " ".join(command.split())


def as_command(text):
    command = " ".join(text.split())
    if command.startswith("$ ") or command.startswith("! "):
        command = command[2:].lstrip()
    if not command.startswith("orch "):
        return None
    return prepare(command)


def commands(path):
    """(line, command) for every line or inline span of the file that starts with `orch `."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    found = []
    fence = False
    continued = None                    # a fenced shell line continued with a backslash
    pending = None                      # inline text whose backticks are not paired yet
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            if continued is not None:
                found.append((continued[0], prepare(continued[1])))
                continued = None
            if pending is not None:
                for start, span in inline_spans(*pending):
                    command = as_command(span)
                    if command:
                        found.append((start, command))
                pending = None
            fence = not fence
            continue
        if fence:
            text = stripped
            if text.startswith("$ ") or text.startswith("! "):
                text = text[2:].lstrip()
            if text.startswith("orch "):
                if continued is not None:
                    text = continued[1] + " " + text
                    number_of = continued[0]
                else:
                    number_of = number
                if text.endswith("\\"):
                    continued = (number_of, text[:-1].rstrip())
                else:
                    found.append((number_of, prepare(text)))
                    continued = None
            elif continued is not None:      # the rest of a command continued with a backslash
                if text.endswith("\\"):
                    continued = (continued[0], continued[1] + " " + text[:-1].rstrip())
                else:
                    found.append((continued[0], prepare(continued[1] + " " + text)))
                    continued = None
            continue
        # outside a fence: inline code spans, including one broken across a line break
        pending = (number, line) if pending is None else (pending[0], pending[1] + "\n" + line)
        if pending[1].count("`") % 2 == 0:
            for start, span in inline_spans(*pending):
                command = as_command(span)
                if command:
                    found.append((start, command))
            pending = None
    if continued is not None:
        found.append((continued[0], prepare(continued[1])))
    return found


root_dir = os.path.dirname(os.path.dirname(os.path.abspath(plugin)))       # the repository root
checked = 0
problems = []
for path in docs:
    if not os.path.isfile(path):
        problems.append((path, 0, "the file is missing"))
        continue
    name = os.path.relpath(path, root_dir).replace(os.sep, "/")             # plugins/partitura/...
    for number, command in commands(path):
        checked += 1
        for where, token, reason in check(command, "%s:%d" % (name, number)):
            problems.append((where, token, reason))

if checked < 20:
    print("only %d orch commands found in the docs: the extraction is probably broken" % checked)
    sys.exit(1)
if problems:
    for where, token, reason in problems:
        print("%s: %r: %s" % (where, token, reason))
    print("checked %d orch commands in %d files, %d problems" % (checked, len(docs), len(problems)))
    sys.exit(1)
print("checked %d orch commands in %d files" % (checked, len(docs)))
EOF
); dc_rc=$?
if [[ $dc_rc -eq 0 ]]; then
  ok "every orch command in the docs exists in the parser ($dc_out)"
else
  bad "the docs name orch commands or options the parser does not have"
  printf '%s\n' "$dc_out"
fi
