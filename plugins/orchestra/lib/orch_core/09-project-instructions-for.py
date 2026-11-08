# ───────────────────────── project instructions for workers ─────────────────────────
#
# Claude Code reads CLAUDE.md (with @imports), Codex and Antigravity read AGENTS.md, and a DeepSeek worker
# (--setting-sources user) reads nothing. orch hands each adapter the files its agent does not read itself
# ('# orch-context-native: AGENTS.md'), so the same project rules reach every executor exactly once.

INSTRUCTION_FILES = ("AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md")
IMPORT_RE = re.compile(r"^@(\S+)\s*$", re.M)
CONTEXT_LIMIT = 40000


def instruction_files(cwd, twin=None):
    """Existing instruction files for a working directory: repository top level first, then cwd."""
    cwd = Path(cwd).resolve()
    dirs = [cwd]
    r = git(["rev-parse", "--show-toplevel"], cwd) if cwd.is_dir() else None
    if r is not None and r.returncode == 0 and r.stdout.strip():
        top = Path(r.stdout.strip()).resolve()
        if top != cwd:
            dirs.insert(0, top)
    result = []
    for d in dirs:
        for name in INSTRUCTION_FILES:
            path = d / name
            if path.is_file():
                result.append((d, name, path))
            elif twin:
                copy = twin(path)
                if copy != path and copy.is_file():
                    check = git(["check-ignore", "-q", "--", str(copy)], copy.parent)
                    if check is not None and check.returncode == 0:
                        result.append((d, name, copy))
    return result


def main_folder_twin(cwd):
    """f(path) → that path's copy in the project folder, when a worktree lacks it: a worktree holds no git-ignored files,
    such as notes on this machine. None outside a worktree."""
    cwd = Path(cwd).resolve()
    r = git(["rev-parse", "--show-toplevel"], cwd) if cwd.is_dir() else None
    if r is None or r.returncode != 0 or not r.stdout.strip():
        return None
    top, main = Path(r.stdout.strip()).resolve(), project_root(cwd).resolve()
    if top == main:
        return None

    def twin(target):
        try:
            copy = main / target.relative_to(top)
        except ValueError:
            return target
        return copy if copy.is_file() else target
    return twin


def expand_imports(path, native, seen, depth=0, twin=None, source=None):
    """Text of an instruction file with whole-line @imports inlined (files the agent reads itself are skipped)."""
    seen.add(path.resolve())
    text = (source or path).read_text(encoding="utf-8", errors="replace")

    def inline(m):
        target = (path.parent / os.path.expanduser(m.group(1))).resolve()
        source = twin(target) if twin and not target.is_file() else target
        native_present = target.name in native and target.is_file()
        if native_present or target in seen or depth >= 3 or not source.is_file():
            return "" if native_present or target in seen else m.group(0)
        return expand_imports(target, native, seen, depth + 1, twin, source)
    return IMPORT_RE.sub(inline, text)


def build_context(cwd, native, out):
    """Write the project instructions an agent does not load natively to `out`; None if there are none."""
    parts, seen = [], set()
    twin = main_folder_twin(cwd)
    for d, name, source in instruction_files(cwd, twin):
        p = (d / name).resolve()
        if (name in native and source.resolve() == p) or p in seen:     # a native file the agent can't find still goes in
            continue
        text = expand_imports(p, native, seen, twin=twin, source=source).strip()
        if text:
            if len(text) > CONTEXT_LIMIT:
                text = text[:CONTEXT_LIMIT] + "\n…[truncated]"
            parts.append("# Project instructions (%s)\n\n%s" % (name, text))
    if not parts:
        return None
    out.write_text("\n\n---\n\n".join(parts) + "\n", encoding="utf-8")
    return out


