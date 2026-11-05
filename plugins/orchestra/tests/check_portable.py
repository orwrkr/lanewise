#!/usr/bin/env python3
"""Keep this machine out of the repository: absolute paths, user names, local identities, private names (AGENTS.md).

    check_portable.py [--root DIR]        every tracked or new file (the self-test and CI run this)
    check_portable.py --staged            what is about to be committed (.githooks/pre-commit)
    check_portable.py --message FILE      a commit message (.githooks/commit-msg)
    check_portable.py --push              what a push would send; refs on stdin (.githooks/pre-push)

Exit 0 clean, 1 findings. Nothing here is specific to one machine: identities and private names are read at run time,
never listed. Examples in docs and tests use the placeholders below: /path/to/…, <you>, the user `me`, ~, $HOME, and
neutral labels such as `client`.
"""
import argparse
import getpass
import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

# What may stand where a user name goes in an example; compared in lower case.
PLACEHOLDER_USERS = {"me", "you", "user", "username", "name", "example", "public", "default", "shared", "...", "…"}
# Never treated as an identity: too generic, or the names CI machines use.
GENERIC_NAMES = {"root", "user", "admin", "administrator", "runner", "runneradmin", "ubuntu", "home", "github", "test", "ci",
                 "ci@example.invalid"}
# Profile labels and folders that name nothing private, and the standard key variables.
GENERIC_LABELS = {"default", "personal", "work", "main", "off", "inherit", "login", "key", "client", "orchestra", "orchestrator"}
STANDARD_KEYS = {"deepseek_api_key", "anthropic_api_key", "anthropic_auth_token", "openai_api_key", "codex_api_key",
                 "gemini_api_key", "google_api_key"}
# A drive path below these is the same on every machine.
SYSTEM_DIRS = ("program", "windows", "path/")      # Program Files, ProgramData; matches stop at a space

# Not inside a longer token: https://x/home/y, $T/home/z and STATUS:\s are not absolute paths.
START = r"(?<![\w$}\].~/\\:-])"
USER_PATH = re.compile(START + r"(?:[A-Za-z]:[\\/]+|/[A-Za-z]/|/mnt/[a-z]/|/cygdrive/[a-z]/|/)"
                               r"(?:Users|users|home)[\\/]+([^\\/\s\"'`<>|:*?)\],;]+)")
DRIVE_PATH = re.compile(START + r"[A-Za-z]:[\\/]+([A-Za-z0-9_~][^\s\"'`<>|*?)\],;]*)")
MOUNT_PATH = re.compile(START + r"/(?:mnt|cygdrive)/[a-z]/([A-Za-z0-9_~][^\s\"'`<>|*?)\],;]*)")
SELF = Path(__file__).name


def placeholder_user(name):
    return name.lower() in PLACEHOLDER_USERS or name[0] in "<$%{[" or "…" in name


def local_identities(root):
    """This machine's user name, host and git e-mail, as they are now."""
    names = {os.environ.get(v) for v in ("USER", "USERNAME", "LOGNAME")}
    names.add(Path.home().name)
    for read in (getpass.getuser, socket.gethostname):
        try:
            names.add(read())
        except Exception:
            pass
    r = subprocess.run(["git", "-C", str(root), "config", "user.email"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    names.add(r.stdout.decode("utf-8", "replace").strip())
    return sorted(n for n in names if n and len(n) >= 3 and n.lower() not in GENERIC_NAMES)


def private_names(root):
    """Names of private projects and clients: `private_terms.txt` in ~/.orchestra (one per line, # for a comment), and
    this machine's profile names, key variables and bound folders from profiles.json. None without ~/.orchestra (CI)."""
    home = Path(os.environ.get("ORCH_HOME") or Path.home() / ".orchestra")
    names = set()
    try:
        terms = (home / "private_terms.txt").read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        terms = []
    names.update(t.strip() for t in terms if t.strip() and not t.strip().startswith("#"))
    try:
        data = json.loads((home / "profiles.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    providers = data.get("providers") if isinstance(data.get("providers"), dict) else {}
    for section in providers.values():
        profiles = section.get("profiles") if isinstance(section, dict) else None
        for name, profile in (profiles if isinstance(profiles, dict) else {}).items():
            names.add(name)
            if isinstance(profile, dict) and isinstance(profile.get("key"), str):
                names.add(profile["key"])
    projects = data.get("projects") if isinstance(data.get("projects"), dict) else {}
    names.update(p.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1] for p in projects)
    rules = data.get("project_rules") if isinstance(data.get("project_rules"), dict) else {}
    names.update(p.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1] for p in rules)
    skip = GENERIC_LABELS | STANDARD_KEYS | {root.name.lower()}
    return sorted(n for n in names if n and len(n) >= 3 and n.lower() not in skip)


def matchers(root):
    """(regex, finding) for each name. An identity is matched whole; a private name also inside `a-name_b`, so that
    neither a folder nor a key variable built from it gets through."""
    out = [(re.compile(r"(?<![\w.-])" + re.escape(n) + r"(?![\w-])", re.I), "this machine's identity: " + n)
           for n in local_identities(root)]
    out += [(re.compile(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", re.I), "a private name: " + n)
            for n in private_names(root)]
    return out


def scan_line(line, names):
    found = []
    for m in USER_PATH.finditer(line):
        if not placeholder_user(m.group(1)):
            found.append("a user's home path: " + m.group(0))
    for m in DRIVE_PATH.finditer(line):
        first = m.group(1).lower().replace("\\", "/")
        if not first.startswith(("users/", "users\\")) and not first.startswith(SYSTEM_DIRS):
            found.append("an absolute drive path: " + m.group(0))
    for m in MOUNT_PATH.finditer(line):
        first = m.group(1).lower().replace("\\", "/")
        if not first.startswith("users/"):
            found.append("an absolute mount path: " + m.group(0))
    found += [finding for regex, finding in names if regex.search(line)]
    return found


def scan_text(label, text, names):
    return ["%s:%d: %s" % (label, n, f) for n, line in enumerate(text.splitlines(), 1) for f in scan_line(line, names)]


def git_lines(root, *args):
    r = subprocess.run(["git", "-C", str(root)] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def decode(data):
    return None if b"\0" in data else data.decode("utf-8", "replace")


def git_text(root, *args):
    r = subprocess.run(["git", "-C", str(root)] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else ""


def scan_commit(root, sha, names):
    """A commit's message and the lines it adds. Adding is what publishes: a name it removes is not a finding."""
    out = scan_text(sha[:7] + " message", git_text(root, "show", "-s", "--format=%B", sha), names)
    path = None
    for line in git_text(root, "show", "--format=", "--no-color", "--no-ext-diff", "-U0", "-m", sha).splitlines():
        if line.startswith("+++ "):
            path = line[4:].strip().split("/", 1)[-1]
        elif line.startswith("+") and path and Path(path).name != SELF:
            out += ["%s %s: %s" % (sha[:7], path, f) for f in scan_line(line[1:], names)]
    return out


def scan_push(root, names, refs):
    """What a push would send: commits the remote doesn't have, and annotated tags. The refs as git gives them to
    pre-push: <local ref> <local sha> <remote ref> <remote sha>."""
    out, seen = [], set()
    for ref in refs:
        parts = ref.split()
        if len(parts) != 4 or set(parts[1]) == {"0"}:      # a deletion sends nothing
            continue
        local_ref, local, _, remote = parts
        if git_text(root, "cat-file", "-t", local).strip() == "tag":
            body = git_text(root, "cat-file", "-p", local).split("\n\n", 1)[-1].split("-----BEGIN", 1)[0]
            out += scan_text(local_ref, body, names)
        new = [local + "^{}", "--not", "--remotes"] if set(remote) == {"0"} else ["%s..%s^{}" % (remote, local)]
        for sha in git_text(root, "rev-list", *new).split():
            if sha not in seen:
                seen.add(sha)
                out += scan_commit(root, sha, names)
    return out


def scan_worktree(root, identities):
    paths = git_lines(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    if paths is None:
        if not (root / ".git").exists():
            print("check_portable: %s is not a git repository, nothing to check" % root)
            return []
        # git can't read it (a worktree made on Windows, seen from WSL): that must not pass as clean
        paths = [str(p.relative_to(root)) for p in sorted(root.rglob("*"))
                 if not {".git", ".orchestra", "__pycache__"} & set(p.relative_to(root).parts)]
    out = []
    for rel in paths:
        path = root / rel
        if path.name != SELF and path.is_file():
            text = decode(path.read_bytes())
            if text is not None:
                out += scan_text(rel, text, identities)
    return out


def scan_staged(root, identities):
    out = []
    for rel in git_lines(root, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR") or []:
        if Path(rel).name == SELF:
            continue
        r = subprocess.run(["git", "-C", str(root), "show", ":" + rel], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        text = decode(r.stdout) if r.returncode == 0 else None
        if text is not None:
            out += scan_text(rel, text, identities)
    return out


def main():
    p = argparse.ArgumentParser(description="Keep this machine out of the repository.")
    p.add_argument("--root", default=".", help="repository root (default: the current directory)")
    p.add_argument("--staged", action="store_true", help="check what is staged")
    p.add_argument("--message", metavar="FILE", help="check a commit message")
    p.add_argument("--push", action="store_true", help="check what a push would send (refs on stdin)")
    a = p.parse_args()
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    root = Path(a.root).resolve()
    identities = matchers(root)
    if a.push:
        findings = scan_push(root, identities, sys.stdin.read().splitlines())
    elif a.message:
        lines = Path(a.message).read_text(encoding="utf-8", errors="replace").splitlines()
        text = "\n".join(line for line in lines if not line.startswith("#"))
        findings = scan_text("commit message", text, identities)
    elif a.staged:
        findings = scan_staged(root, identities)
    else:
        findings = scan_worktree(root, identities)
    if findings:
        print("Machine-specific content (AGENTS.md: the repository must work from any location):", file=sys.stderr)
        for line in findings:
            print("  " + line, file=sys.stderr)
        print("Use /path/to/…, <you>, ~ or $HOME; in test data, the user `me`; a neutral label such as `client`.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
