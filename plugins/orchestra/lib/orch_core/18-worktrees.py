# ───────────────────────── worktrees ─────────────────────────

def worktree_branch_at(path, proj):
    """The branch of the git worktree rooted exactly at `path`, if it belongs to proj's repository, else None. Git asked
    inside a plain folder under the project answers for the project around it, so a commit there would land on the
    project's own branch: the root and the repository are both compared. A detached HEAD gives 'HEAD'."""
    if not Path(path).is_dir():
        return None

    def common(cwd):
        r = git(["rev-parse", "--git-common-dir"], cwd)
        if r is None or r.returncode != 0:
            return None
        c = Path(r.stdout.strip())
        return c if c.is_absolute() else Path(cwd) / c
    top, head = git(["rev-parse", "--show-toplevel"], path), git(["rev-parse", "--abbrev-ref", "HEAD"], path)
    mine, theirs = common(path), common(proj)
    if not (top and head and mine and theirs) or top.returncode != 0 or head.returncode != 0:
        return None
    try:
        same = os.path.samefile(top.stdout.strip(), str(path)) and os.path.samefile(str(mine), str(theirs))
    except OSError:
        return None
    return head.stdout.strip() if same else None


def make_worktree(name, base="HEAD", branch=None, root=None):
    """A git worktree `name` on `branch`: next to the project in <project>.wt/ unless `root` says where. Something
    already at that path is reused only if it really is that worktree."""
    proj = project_dir()
    r = git(["rev-parse", "--is-inside-work-tree"], proj)
    if r is None or r.returncode != 0:
        raise SystemExit("orch: %s is not a git repository — worktree unavailable" % proj)
    wt_root = Path(root) if root else proj.parent / (proj.name + ".wt")
    path = wt_root / name
    wanted, branch = branch, branch or ("orch/" + name.lower())
    if path.exists():
        actual = worktree_branch_at(path, proj)
        if actual is None:
            raise SystemExit("orch: %s exists but is not a working git worktree of this repository (a plain folder, "
                             "another repository, or links broken by a move: see git worktree repair). Sort it out or "
                             "remove it, then try again." % path)
        if wanted and actual != wanted:
            raise SystemExit("orch: the worktree %s is on branch %s, not %s. Sort it out or remove it, then try again."
                             % (path, actual, wanted))
        return path, actual
    wt_root.mkdir(parents=True, exist_ok=True)
    exists = git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], proj)
    args = ["worktree", "add", str(path), branch] if exists and exists.returncode == 0 else \
        ["worktree", "add", "-b", branch, str(path), base]
    git(args, proj, check=True)
    ensure_git_exclude(proj)
    return path, branch


def cmd_worktree(a):
    path, branch = make_worktree(a.name, a.base, a.branch)
    print("worktree: %s\nbranch:   %s" % (path, branch))
    w = win_path(path)
    if w:
        print("windows:  %s" % w)
    return 0


