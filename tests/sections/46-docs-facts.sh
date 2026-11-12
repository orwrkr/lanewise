# needs:
echo "── public documents match the code (network requests, personal files, version)"
# A static check of the repository — no orch runs, so it stays fast. The public documents make claims about what the
# plugin requests and where it writes; each claim is tied to the code here: a new network import or URL, a new name
# joined onto the personal folder, or a version bump in one place only fails and says what to update.
df_out=$($PY -B - "$(native "$PLUGIN")" <<'EOF'
import glob
import json
import os
import re
import sys

plugin = os.path.abspath(sys.argv[1])
repo = os.path.dirname(os.path.dirname(plugin))


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def rel(path):
    return os.path.relpath(path, repo).replace(os.sep, "/")


# ── 1. network code is disclosed ───────────────────────────────────────────────────────────────────────────────────
# Every file that can make a request: the CLI code, the adapters and the launchers.
core = sorted(glob.glob(os.path.join(plugin, "lib", "orch_core", "*.py")))
adapters = sorted(p for p in glob.glob(os.path.join(plugin, "adapters", "*")) if os.path.isfile(p))
binaries = sorted(p for p in glob.glob(os.path.join(plugin, "bin", "*")) if os.path.isfile(p))   # not bin/__pycache__
sources = {rel(p): read(p) for p in core + adapters + binaries}

# urllib.parse and urllib.error are not requests; only urllib.request, http.client, socket, ssl, ftplib, smtplib
# and requests are. Each importing file must be listed with the request it makes.
NET_IMPORT = re.compile(
    r"^\s*(?:import|from)\s+(urllib\.request|http\.client|socket|ssl|ftplib|smtplib|requests)\b", re.M)
NETWORK_IMPORTERS = {
    "plugins/lanewise/lib/orch_core/15-provider-account-balances.py":
        "reads the provider's own account balance: GET https://api.deepseek.com/user/balance",
}

# A URL literal in those files is a request unless it is listed here with a reason. Every other host must be named
# in both PRIVACY.md and the README section "What it runs, sends and fetches".
URL = re.compile(r"https?://[^\s\"'`<>()\[\]{}]*")
HOST = re.compile(r"https?://([^/:?#]+)")
NOT_A_REQUEST = {
    "https://...": "a placeholder in the JSON schema of the task `orch prices check` writes; orch makes no request",
}


def check_imports(found, allowed):
    problems = []
    for path, text in found.items():
        for m in NET_IMPORT.finditer(text):
            if path not in allowed:
                problems.append(
                    "%s imports %s: disclose the request in PRIVACY.md and in the README section \"What it runs, "
                    "sends and fetches\", then add the file to NETWORK_IMPORTERS in this test with a one-line reason"
                    % (path, m.group(1)))
    for path in allowed:
        if path not in found or not NET_IMPORT.search(found[path]):
            problems.append("%s is in NETWORK_IMPORTERS but no longer imports a network module: remove it or "
                            "explain its reason again" % path)
    return problems


def check_urls(found, privacy, readme_section, allowed):
    problems = []
    seen = set()
    for path, text in found.items():
        for m in URL.finditer(text):
            url = m.group(0)
            host_match = HOST.match(url)
            if not host_match or not host_match.group(1):
                continue                    # "https://" + user input: a scheme prefix, not a request
            host = host_match.group(1).lower()
            seen.add(url)
            if url in allowed:
                continue
            missing = [name for name, doc in (
                ("PRIVACY.md", privacy),
                ("the README section \"What it runs, sends and fetches\"", readme_section)) if host not in doc.lower()]
            if missing:
                problems.append(
                    "%s: %s (host %s) is not named in %s: disclose the request there, or add the URL to "
                    "NOT_A_REQUEST in this test with a reason" % (path, url, host, " or ".join(missing)))
    for url in allowed:
        if url not in seen:
            problems.append("NOT_A_REQUEST lists %s, which no scanned file uses: remove it" % url)
    return problems


# ── 2. every file in the personal folder is listed ─────────────────────────────────────────────────────────────────
# The names joined onto ORCH_HOME (or the personal folder the adapters and launchers resolve), in the CLI code, the
# adapters and the launchers. A name is in the README table "Where things are stored", or internal bookkeeping here.
HOME_JOIN = re.compile(r"ORCH_HOME\s*/\s*[\"']([^\"']+)[\"']")
ADAPTER_HOME_JOIN = re.compile(r"(?:orch_home\(\)|home)\s*/\s*[\"']([^\"']+)[\"']")
HOOK_CACHE = re.compile(r"HOME_DIR/(\.hook-python-)[^\s\"'/]*")
PY_CACHE = re.compile(r"_os\.path\.join\(home,\s*[\"']([^\"']+)[\"']")

INTERNAL_HOME_FILES = {
    ".balance-refresh": "when a hook last started a detached balance fetch, so hooks start at most one every two minutes",
    ".watch-post-tool": "the limit-watch marker per session after a tool call",
    ".watch-spend.json": "the spend figures the watcher compares between checks",
    ".state.lock": "the lock around shared personal state",
    ".usage.lock": "the lock around the usage log",
    ".settings.lock": "the lock around the Claude settings the key helper writes",
    ".session_budget.lock": "the lock around the per-session budget baselines",
    ".watch-spend.lock": "the lock around the watcher's spend figures",
    ".pycache": "compiled bytecode of lib/orch_core, as Python's own __pycache__",
    ".hook-python-<platform>": "the interpreter a hook or the launcher found, cached per platform",
    "session_tokens.json": "the old single-file session token cache, read only to migrate one session",
    "spend_cache.json": "token costs read from the executors' logs so far, for the spend counters",
    "spend_events.json": "which spend warnings and fallback moves were already announced, so a repeated hook stays quiet",
}


def personal_names():
    names = {}

    def add(name, where):
        names.setdefault(name, set()).add(where)

    for path in core:
        for m in HOME_JOIN.finditer(read(path)):
            add(m.group(1), rel(path))
    for path in adapters:
        for m in ADAPTER_HOME_JOIN.finditer(read(path)):
            add(m.group(1), rel(path))
    for name in ("plugins/lanewise/bin/orch", "plugins/lanewise/hooks/run.sh"):
        path = os.path.join(repo, *name.split("/"))
        if not os.path.isfile(path):
            continue
        text = read(path)
        for _ in HOOK_CACHE.finditer(text):         # $HOME_DIR/.hook-python-<platform>
            add(".hook-python-<platform>", name)
        for m in PY_CACHE.finditer(text):           # _os.path.join(home, ".pycache", ...)
            add(m.group(1), name)
    return names


def readme_section(text, heading):
    """The lines of a Markdown section, from its heading to the next heading of level 1 to 3."""
    out = []
    inside = False
    for line in text.splitlines():
        if not inside:
            if line.strip() == heading:
                inside = True
            continue
        if re.match(r"^#{1,3}\s", line):
            break
        out.append(line)
    return "\n".join(out)


def storage_table(readme):
    section = readme_section(readme, "## Where things are stored")
    return re.findall(r"^\|\s*`([^`]+)`\s*\|", section, re.M)


def check_storage(names, table, internal):
    problems = []
    for name in sorted(names):
        if name in internal:
            continue
        needle = "~/.lanewise/" + name
        if not any(p == needle or p.startswith(needle + "/") for p in table):
            problems.append(
                "~/.lanewise/%s (%s) is not in the README table \"Where things are stored\": add a row for it, or "
                "list it in INTERNAL_HOME_FILES in this test with a reason"
                % (name, ", ".join(sorted(names[name]))))
    for name in internal:
        if name not in names:
            problems.append("INTERNAL_HOME_FILES lists %s (%s), which the code no longer stores: remove it"
                            % (name, internal[name]))
    return problems


# ── 3. the version matches the changelog ──────────────────────────────────────────────────────────────────────────
def check_version(version, changelog):
    m = re.search(r"^##\s+(\d+\.\d+\.\d+)\b", changelog, re.M)
    if not m:
        return ["CHANGELOG.md has no \"## X.Y.Z\" heading"]
    if m.group(1) != version:
        return ["plugin.json says %s but the first CHANGELOG.md heading is %s: bump the version in both places"
                % (version, m.group(1))]
    return []


# ── each check can fail: run it once on a made-up input that must be rejected ─────────────────────────────────────
def must_fail(name, problems):
    if problems:
        return []
    return ["the %s check passed a made-up input that must fail, so it cannot catch a real one" % name]


problems = []
problems += must_fail("network imports", check_imports({"x.py": "import socket\n"}, {}))
problems += must_fail("URLs", check_urls({"x.py": "URL = \"https://not-disclosed.invalid/x\"\n"},
                                         "no host here", "none here either", {}))
problems += must_fail("personal files", check_storage({"made-up.json": {"x.py"}},
                                                      ["~/.lanewise/availability.json"], {}))
problems += must_fail("version", check_version("0.0.1", "## 0.0.2\n"))
if problems:
    for p in problems:
        print(p)
    sys.exit(1)

# ── the real check ────────────────────────────────────────────────────────────────────────────────────────────────
missing = [p for p in (os.path.join(repo, "PRIVACY.md"), os.path.join(repo, "CHANGELOG.md"),
                       os.path.join(plugin, "README.md"), os.path.join(plugin, ".claude-plugin", "plugin.json"))
           if not os.path.isfile(p)]
if missing:
    for p in missing:
        print("%s is missing" % rel(p))
    sys.exit(1)

privacy = read(os.path.join(repo, "PRIVACY.md"))
readme = read(os.path.join(plugin, "README.md"))
section = readme_section(readme, "### What it runs, sends and fetches")
if not section.strip():
    print("plugins/lanewise/README.md has no section \"### What it runs, sends and fetches\"")
    sys.exit(1)

problems = []
problems += check_imports(sources, NETWORK_IMPORTERS)
problems += check_urls(sources, privacy, section, NOT_A_REQUEST)
names = personal_names()
table = storage_table(readme)
problems += check_storage(names, table, INTERNAL_HOME_FILES)
try:
    version = json.loads(read(os.path.join(plugin, ".claude-plugin", "plugin.json"))).get("version") or ""
except ValueError as ex:
    problems.append("plugins/lanewise/.claude-plugin/plugin.json is not JSON: %s" % ex)
    version = ""
problems += check_version(version, read(os.path.join(repo, "CHANGELOG.md")))
if problems:
    for p in problems:
        print(p)
    sys.exit(1)

importers = sorted({p for p, text in sources.items() if NET_IMPORT.search(text)})
urls = sorted({m.group(0) for text in sources.values() for m in URL.finditer(text)
               if HOST.match(m.group(0)) and HOST.match(m.group(0)).group(1)})
in_table = len([n for n in names if n not in INTERNAL_HOME_FILES])
print("%d files scanned: %d network importer(s), %d hosted URL(s); %d personal-folder names (%d in the README "
      "table, %d internal); version %s matches CHANGELOG.md"
      % (len(sources), len(importers), len(urls), len(names), in_table, len(names) - in_table, version))
EOF
); df_rc=$?
if [[ $df_rc -eq 0 ]]; then
  ok "$df_out"
else
  bad "the public documents do not match the code"
  printf '%s\n' "$df_out"
fi
