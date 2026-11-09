# ───────────────────────── registry ─────────────────────────

REGISTRY_BUILTIN = PLUGIN_ROOT / "registry" / "providers.yaml"
REGISTRY_MARKER_PREFIX = "# orchestra-registry-base:"      # kept from the plugin's old name: personal copies carry it
REGISTRY_MARKER_RE = re.compile(r"^# orchestra-registry-base:\s*(\S+)\s+sha256:([0-9a-f]{16})\s*$")
PLUGIN_NAME = "partitura"
LEGACY_PLUGIN_NAME = "orchestra"                            # the plugin's name before 0.34.0
LEGACY_AGENT_RE = re.compile(r"^(\s*agent:\s*[\"']?)orchestra:".encode(), re.M)


def current_agent(name):
    """A subagent type under the plugin's current name. A personal registry made before 0.34.0 still says
    `orchestra:orch-…`, which Claude Code no longer has: the old prefix means the new one."""
    prefix = LEGACY_PLUGIN_NAME + ":"
    if isinstance(name, str) and name.startswith(prefix):
        return PLUGIN_NAME + ":" + name[len(prefix):]
    return name


def registry_current_agents(data):
    """Every slot's agent under the plugin's current name (current_agent), in place; returns data."""
    providers = data.get("providers") if isinstance(data, dict) else None
    for prov in providers.values() if isinstance(providers, dict) else []:
        slots = prov.get("slots") if isinstance(prov, dict) else None
        for s in slots if isinstance(slots, list) else []:
            if isinstance(s, dict) and "agent" in s:
                s["agent"] = current_agent(s["agent"])
    return data


def registry_path():
    for p in (project_dir() / ".orchestra" / "providers.yaml", ORCH_HOME / "providers.yaml",
              PLUGIN_ROOT / "registry" / "providers.yaml"):
        if p.exists():
            return p
    return PLUGIN_ROOT / "registry" / "providers.yaml"


def plugin_version():
    """The plugin version from .claude-plugin/plugin.json (for the registry marker), or '?' when unreadable."""
    try:
        data = json.loads((PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        return str(data.get("version") or "?")
    except Exception:
        return "?"


def registry_builtin():
    """(text, first 16 hex of the SHA-256) of the built-in registry."""
    import hashlib
    data = REGISTRY_BUILTIN.read_bytes()
    return data.decode("utf-8"), hashlib.sha256(data).hexdigest()[:16]


def registry_body(text):
    """The registry's lines without the marker line: what a copy really adds or changes."""
    return [line for line in text.splitlines() if not line.startswith(REGISTRY_MARKER_PREFIX)]


def registry_marker(text):
    """(version, hash) recorded in the copy's marker line, or None."""
    for line in text.splitlines():
        m = REGISTRY_MARKER_RE.match(line)
        if m:
            return m.group(1), m.group(2)
    return None


def registry_copy_state():
    """(is_copy, stale, version) for the registry in effect: whether it is a personal/project copy, whether that
    copy has gone stale against the built-in registry, and the version recorded in its marker (None without one).
    Never raises: any error reads as "no copy, not stale"."""
    try:
        cur = registry_path()
        if cur == REGISTRY_BUILTIN:
            return False, False, None
        text = cur.read_text(encoding="utf-8")
        builtin_text, digest = registry_builtin()
        marker = registry_marker(text)
        if marker is not None:
            return True, marker[1] != digest, marker[0]
        return True, registry_body(text) != registry_body(builtin_text), None
    except Exception:
        return False, False, None


def registry_stale_note():
    """The one-line warning for status and doctor when the copy in effect lags the built-in registry, else None.
    Never raises."""
    _, stale, version = registry_copy_state()
    if not stale:
        return None
    return ("the built-in registry has changed since this copy was made (%s): orch registry diff"
            % (version or "an older version"))


def registry_marker_line():
    version, digest = plugin_version(), registry_builtin()[1]
    return "# orchestra-registry-base: %s sha256:%s" % (version, digest)


def registry_write(path, text):
    """Write LF-only (the repository and its registry are LF, also on Windows)."""
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def registry_diff(a):
    if registry_path() == REGISTRY_BUILTIN:
        print("No personal or project copy: the built-in registry is in effect.")
        return 0
    import difflib
    cur = registry_path()
    builtin_text, digest = registry_builtin()
    copy_text = cur.read_text(encoding="utf-8")
    if a.accept:
        body = registry_body(copy_text)
        registry_write(cur, registry_marker_line() + "\n" + ("\n".join(body) + "\n" if body else ""))
        print("accepted: %s now records %s sha256:%s" % (cur, plugin_version(), digest))
        return 0
    lines = list(difflib.unified_diff(registry_body(builtin_text), registry_body(copy_text),
                                      fromfile=str(REGISTRY_BUILTIN), tofile=str(cur), lineterm=""))
    if lines:
        print("\n".join(lines))
    print("This copy overrides the whole built-in registry. Take over what you need from the built-in one, "
          "then record it as current: orch registry diff --accept")
    return 0


class RegistryParseError(Exception):
    pass


REGISTRY_KEY_RE = re.compile(r"""^("[^"]*"|'[^']*'|[A-Za-z0-9_@][^:#]*?)\s*:(?:\s+(.*))?$""")
REGISTRY_SECTIONS = ("version", "policy", "operator", "difficulty", "providers", "routing")
REGISTRY_PROVIDER_FIELDS = ("lane", "billing", "quota_key", "efforts", "invoke", "invoke_when_not_lead", "notes",
                            "slots")
REGISTRY_SLOT_FIELDS = ("id", "model", "effort", "cost", "max_difficulty", "good_for", "agent")
REGISTRY_LEGEND = "slots: id  model  effort  c<cost> d<max_difficulty>  good_for  [agent=…]  [other fields as key=value]"
REGISTRY_FOOTER = ("A provider's notes: orch registry show <provider> · "
                   "the whole file: orch registry show --full")


def registry_strip_comment(s):
    """(text, comment) of one line: a ` #` outside quotes starts the comment. A quote opens only where a token
    begins, so the apostrophe of `operator's` is text."""
    quote = None
    for i, ch in enumerate(s):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"" and (i == 0 or s[i - 1] in " \t[,"):
            quote = ch
        elif ch == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip(), s[i + 1:].strip()
    return s.rstrip(), ""


def registry_scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    if re.match(r"^-?\d+$", s):
        return int(s)
    if s in ("true", "false"):
        return s == "true"
    return s


def registry_flow_items(s):
    """The items of a flow list's inside (`a, b, c`): split at commas outside quotes and brackets."""
    items, cur, depth, quote = [], "", 0, None
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "'\"" and not cur.strip():
            quote = ch
            cur += ch
        elif ch in "[{":
            depth += 1
            cur += ch
        elif ch in "]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            items.append(cur)
            cur = ""
        else:
            cur += ch
    items.append(cur)
    return [registry_scalar(x) for x in items if x.strip()]


def registry_parse(text):
    """(data, route_comments) for the subset of YAML the registry uses: maps nested by indentation, `- ` lists (of
    scalars or of maps), flow lists `[a, b]` that may span lines, folded scalars (`key: >`), plain and quoted
    scalars (digits become ints, true/false booleans) and comments. Unknown keys are kept. route_comments holds the
    trailing comment of each `routing` line, {route name: comment}. Raises RegistryParseError on anything else."""
    rows = []                                    # None for a blank line, else [indent, text, line number, comment-only]
    for n, raw in enumerate(text.lstrip("\ufeff").splitlines(), 1):
        body = raw.strip()
        if not body:
            rows.append(None)
            continue
        lead = raw[:len(raw) - len(raw.lstrip())]
        if "\t" in lead:
            raise RegistryParseError("line %d: a tab in the indentation" % n)
        rows.append([len(lead), body, n, body.startswith("#")])
    count, route_comments, pos = len(rows), {}, [0]

    def peek():
        while pos[0] < count and (rows[pos[0]] is None or rows[pos[0]][3]):
            pos[0] += 1
        return rows[pos[0]] if pos[0] < count else None

    def is_item(row):
        return row[1] == "-" or row[1].startswith("- ")

    def flow_list(first, lineno):
        buf = first
        while buf.count("[") > buf.count("]"):
            if pos[0] >= count:
                raise RegistryParseError("line %d: a list that is never closed" % lineno)
            row = rows[pos[0]]
            pos[0] += 1
            if row is not None and not row[3]:
                buf += " " + registry_strip_comment(row[1])[0]
        if not buf.endswith("]"):
            raise RegistryParseError("line %d: text after a closing bracket" % lineno)
        return registry_flow_items(buf[1:-1])

    def folded(indent, style):
        parts = []
        while pos[0] < count:
            row = rows[pos[0]]
            if row is None:
                parts.append("")
            elif row[0] <= indent:
                break
            else:
                parts.append(row[1])
            pos[0] += 1
        while parts and parts[-1] == "":
            parts.pop()
        if style == "|":
            return "\n".join(parts)
        paragraphs, cur = [], []
        for part in parts:
            if part:
                cur.append(part)
            elif cur:
                paragraphs.append(" ".join(cur))
                cur = []
        if cur:
            paragraphs.append(" ".join(cur))
        return "\n".join(paragraphs)

    def value(text, indent, lineno):
        if text.startswith("["):
            return flow_list(text, lineno)
        if re.match(r"^[>|][+-]?$", text):
            return folded(indent, text[0])
        return registry_scalar(text)

    def block(indent, path):
        return block_list(indent, path) if is_item(peek()) else block_map(indent, path)

    def block_map(indent, path):
        out = {}
        while True:
            row = peek()
            if row is None or row[0] < indent:
                return out
            if row[0] > indent:
                raise RegistryParseError("line %d: unexpected indentation" % row[2])
            if is_item(row):
                raise RegistryParseError("line %d: a list item where a key is expected" % row[2])
            text, comment = registry_strip_comment(row[1])
            m = REGISTRY_KEY_RE.match(text)
            if not m:
                raise RegistryParseError("line %d: not a `key: value` line" % row[2])
            key, rest = registry_scalar(m.group(1)), (m.group(2) or "").strip()
            pos[0] += 1
            if path == ("routing",) and comment:
                route_comments[key] = comment
            if rest:
                out[key] = value(rest, indent, row[2])
                continue
            nxt = peek()
            if nxt is not None and (nxt[0] > indent or (nxt[0] == indent and is_item(nxt))):
                out[key] = block(nxt[0], path + (key,))
            else:
                out[key] = None

    def block_list(indent, path):
        out = []
        while True:
            row = peek()
            if row is None or row[0] < indent:
                return out
            if row[0] > indent:
                raise RegistryParseError("line %d: unexpected indentation" % row[2])
            if not is_item(row):
                return out                       # the list ended: a sibling key follows
            rest = row[1][1:].lstrip()
            text = registry_strip_comment(rest)[0]
            if not rest:
                pos[0] += 1
                nxt = peek()
                out.append(block(nxt[0], path) if nxt is not None and nxt[0] > indent else None)
            elif REGISTRY_KEY_RE.match(text) and not text.startswith("["):
                row[0] += len(row[1]) - len(rest)         # the item's keys line up behind the dash
                row[1] = rest
                out.append(block_map(row[0], path))
            else:
                pos[0] += 1
                out.append(value(text, indent, row[2]))

    first = peek()
    if first is None:
        return {}, {}
    if is_item(first):
        raise RegistryParseError("line %d: a list at the top level" % first[2])
    data = block_map(first[0], ())
    leftover = peek()
    if leftover is not None:
        raise RegistryParseError("line %d: unexpected indentation" % leftover[2])
    return data, route_comments


def registry_text(v):
    """A parsed value as display text."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return ""
    if isinstance(v, list):
        return ", ".join(registry_text(x) for x in v)
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def registry_map(v):
    return v if isinstance(v, dict) else {}


def registry_settings(d):
    """A section's scalars (to go on one line) and one `key: value` line for each of its lists and maps."""
    d = registry_map(d)
    scalars = ["%s %s" % (k, registry_text(v)) for k, v in d.items() if not isinstance(v, (list, dict))]
    return scalars, ["%s: %s" % (k, registry_text(v)) for k, v in d.items() if isinstance(v, (list, dict))]


def registry_header(key, prov):
    parts = ["%s %s" % (f, registry_text(prov[f])) for f in ("lane", "billing", "quota_key", "efforts") if f in prov]
    parts += ["%s: %s" % (f, registry_text(prov[f])) for f in ("invoke", "invoke_when_not_lead") if f in prov]
    parts += ["%s=%s" % (k, registry_text(v)) for k, v in prov.items() if k not in REGISTRY_PROVIDER_FIELDS]
    return "%s: %s" % (key, " · ".join(parts))


def registry_slot_lines(prov):
    rows = []
    for s in prov["slots"] if isinstance(prov.get("slots"), list) else []:
        if not isinstance(s, dict):
            continue
        cells = [registry_text(s.get("id")) or "?", registry_text(s.get("model")) or "-",
                 registry_text(s.get("effort")) or "-",
                 "c%s d%s" % (registry_text(s.get("cost")) or "-", registry_text(s.get("max_difficulty")) or "-")]
        tail = [registry_text(s.get("good_for"))] if "good_for" in s else []
        if "agent" in s:
            tail.append("agent=%s" % registry_text(s["agent"]))
        tail += ["%s=%s" % (k, registry_text(v)) for k, v in s.items() if k not in REGISTRY_SLOT_FIELDS]
        rows.append((cells, tail))
    # one outlier (a long model name) must not widen a column for every line: it only overflows its own
    widths = [max([len(cells[i]) for cells, _ in rows if len(cells[i]) <= 24] or [0]) for i in range(4)]
    return ["  " + "  ".join(["  ".join(c.ljust(w) for c, w in zip(cells, widths)).rstrip()] + tail)
            for cells, tail in rows]


def registry_route_lines(routing, comments, provider=None):
    """`  name: slot, slot  # comment`; with a provider, only the routes that name one of its slots."""
    names = []
    for name, slots in routing.items():
        items = [registry_text(x) for x in slots] if isinstance(slots, list) else [registry_text(slots)]
        if provider is None or any(x.startswith(provider + "/") for x in items):
            names.append((str(name), ", ".join(items), comments.get(name)))
    return ["  %s: %s%s" % (n, s, "  # " + c if c else "") for n, s, c in names]


def registry_kind(path):
    if path == REGISTRY_BUILTIN:
        return "built-in registry"
    return "personal copy" if path == ORCH_HOME / "providers.yaml" else "project copy"


def registry_brief(data, comments, path):
    """The registry as the orchestrator reads it: settings, slots and routes; a provider's notes stay out."""
    out = ["Registry in effect: %s (%s)" % (registry_kind(path), path)]
    note = registry_stale_note()
    if note:
        out[0] += " · " + note
    for name in ("policy", "operator"):
        scalars, others = registry_settings(data.get(name))
        out += (["%s: %s" % (name, " · ".join(scalars))] if scalars else []) + others
    levels = registry_map(data.get("difficulty"))
    if levels:
        out.append("difficulty: " + " · ".join("%s %s" % (k, re.split(r"\s[—–]", registry_text(v), maxsplit=1)[0].strip())
                                                 for k, v in levels.items()))
    out.append(REGISTRY_LEGEND)
    for key, prov in data["providers"].items():
        prov = registry_map(prov)
        out += [registry_header(key, prov)] + registry_slot_lines(prov)
    routing = registry_map(data.get("routing"))
    if routing:
        out += ["routing (order = preference):"] + registry_route_lines(routing, comments)
    extra = [str(k) for k in data if k not in REGISTRY_SECTIONS]
    if extra:
        out.append("other sections: " + ", ".join(extra))
    return "\n".join(out + [REGISTRY_FOOTER]) + "\n"


def registry_provider_view(data, comments, key):
    """One provider in full: its header, notes as one paragraph, slots and the routes that name them."""
    import textwrap
    prov = registry_map(data["providers"][key])
    out = [registry_header(key, prov)]
    notes = registry_text(prov.get("notes")).strip()
    if notes:
        out.append("notes:")
        out += [textwrap.fill(p, width=110, initial_indent="  ", subsequent_indent="  ")
                for p in notes.split("\n") if p.strip()]
    out += [REGISTRY_LEGEND] + registry_slot_lines(prov)
    routes = registry_route_lines(registry_map(data.get("routing")), comments, key)
    if routes:
        out += ["routes naming %s slots:" % key] + routes
    return "\n".join(out) + "\n"


def registry_emit(raw):
    """The file's own bytes on every platform, except that an agent named under the plugin's old name is shown under
    the current one (current_agent)."""
    raw = LEGACY_AGENT_RE.sub(lambda m: m.group(1) + PLUGIN_NAME.encode() + b":", raw)
    sys.stdout.flush()
    try:
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
    except AttributeError:
        sys.stdout.write(raw.decode("utf-8", "replace"))


def registry_show(a):
    path = registry_path()
    try:
        raw = path.read_bytes()
    except OSError as e:
        print("cannot read %s: %s" % (path, e), file=sys.stderr)
        return 1
    if a.full:
        registry_emit(raw)
        return 0
    wanted = (a.provider or "").lower()
    try:
        data, comments = registry_parse(raw.decode("utf-8"))
        registry_current_agents(data)
        providers = data.get("providers")
        if not isinstance(providers, dict) or not providers:
            raise RegistryParseError("no providers")
        known = {str(k).lower(): k for k in providers}
        if wanted and wanted not in known:
            print("unknown provider %r: the registry has %s" % (a.provider, ", ".join(map(str, providers))),
                  file=sys.stderr)
            return 2
        if a.json:
            body = {known[wanted]: providers[known[wanted]]} if wanted else dict(data, routing_comments=comments)
            text = json.dumps(body, indent=2, ensure_ascii=False) + "\n"
        elif wanted:
            text = registry_provider_view(data, comments, known[wanted])
        else:
            text = registry_brief(data, comments, path)
    except Exception as e:
        reason = str(e) or e.__class__.__name__
        if a.json:
            print("could not read %s as a registry (%s)" % (path, reason), file=sys.stderr)
            return 1
        print("could not read %s as a registry (%s): showing the file as is" % (path, reason))
        registry_emit(raw)
        return 0
    sys.stdout.write(text)
    return 0


def cmd_registry(a):
    if a.action != "show" and (getattr(a, "provider", None) or getattr(a, "full", False) or getattr(a, "json", False)):
        print("a provider, --full and --json belong to `orch registry show`", file=sys.stderr)
        return 2
    if a.action == "path":
        print(registry_path())
    elif a.action == "show":
        if a.full and (a.provider or a.json):
            print("--full prints the whole file: it takes neither a provider nor --json", file=sys.stderr)
            return 2
        return registry_show(a)
    elif a.action == "init":
        dest = (project_dir() / ".orchestra" / "providers.yaml") if a.project else (ORCH_HOME / "providers.yaml")
        if dest.exists() and not a.force:
            print("already exists: %s" % dest)
            return 0
        if a.project:
            state_dir(create=True)
        dest.parent.mkdir(parents=True, exist_ok=True)
        registry_write(dest, registry_marker_line() + "\n" + registry_builtin()[0])
        print("created: %s (edit it; it overrides the built-in registry)" % dest)
    elif a.action == "diff":
        return registry_diff(a)
    return 0


