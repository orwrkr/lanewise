echo "── launcher: compiled once, cached bytecode"
lc_home="$(native "$T/cache-home")"
lc_tag=$($PY -c "import sys; print(sys.implementation.cache_tag or '')" 2>/dev/null)
[[ -n "$lc_tag" ]] && ok "the interpreter has a cache tag ($lc_tag)" || bad "no cache tag from the interpreter"
lc_cache="$lc_home/.pycache/orch_core.$lc_tag.bin"
# the key in the cache file: a sha256 digest, 32 bytes
lc_key() { $PY -c "import sys; print(open(sys.argv[1], 'rb').read()[:32].hex())" "$(native "$1")" 2>/dev/null; }
ORCH_HOME="$lc_home" $ORCH --help >/dev/null 2>&1
[[ -f "$lc_cache" ]] && ok "a first orch call writes the bytecode cache" || bad "no cache file: $lc_cache"
# the cache is a key followed by marshal.dumps() of the parts' code objects: keep the key, swap the code
$PY - "$(native "$lc_cache")" <<'EOF' && ok "a second call runs the code from the cache" || bad "the cached code was not used"
import marshal, sys
with open(sys.argv[1], "rb") as fh:
    key = fh.read()[:32]
with open(sys.argv[1], "wb") as fh:
    fh.write(key + marshal.dumps([compile('print("CACHE-PAYLOAD-RAN")', sys.argv[1], "exec")]))
EOF
out=$(ORCH_HOME="$lc_home" $ORCH --help 2>&1)
contains "$out" "CACHE-PAYLOAD-RAN" "a second call runs the cached code"
rm -f "$lc_cache"
# another copy of the plugin, same ORCH_HOME layout: an edited part is compiled again, not served from the cache
lc_copy="$T/plugin-copy"
mkdir -p "$lc_copy/bin" "$lc_copy/lib/orch_core"
cp "$PLUGIN/bin/orch" "$lc_copy/bin/orch"
cp "$PLUGIN"/lib/orch_core/*.py "$lc_copy/lib/orch_core/"
lc_home2="$(native "$T/cache-home-2")"
ORCH_HOME="$lc_home2" $PY "$lc_copy/bin/orch" --help >/dev/null 2>&1
[[ -f "$lc_home2/.pycache/orch_core.$lc_tag.bin" ]] && ok "a copied plugin writes its cache too" || bad "the copied plugin wrote no cache"
$PY - "$(native "$lc_copy/lib/orch_core/00-header.py")" <<'EOF' || bad "cannot edit the copied part"
import sys
with open(sys.argv[1], "rb") as fh:
    source = fh.read()
with open(sys.argv[1], "wb") as fh:
    fh.write(b'print("FRESH-SOURCE-RAN")\n' + source)
EOF
out=$(ORCH_HOME="$lc_home2" $PY "$lc_copy/bin/orch" --help 2>&1)
contains "$out" "FRESH-SOURCE-RAN" "an edited part is compiled again, not served from the old cache"
# the key covers every part's file name and source: adding, renaming or removing a part rewrites the cache
lc_copy2="$T/plugin-parts"
mkdir -p "$lc_copy2/bin" "$lc_copy2/lib/orch_core"
cp "$PLUGIN/bin/orch" "$lc_copy2/bin/orch"
cp "$PLUGIN"/lib/orch_core/*.py "$lc_copy2/lib/orch_core/"
lc_home3="$(native "$T/cache-home-3")"
lc_cache3="$lc_home3/.pycache/orch_core.$lc_tag.bin"
ORCH_HOME="$lc_home3" $PY "$lc_copy2/bin/orch" --help >/dev/null 2>&1
lc_key0=$(lc_key "$lc_cache3")
# a part before the last one (28-argparse.py ends with the __main__ call)
printf 'print("EXTRA-PART-RAN")\n' > "$lc_copy2/lib/orch_core/01-extra.py"
out=$(ORCH_HOME="$lc_home3" $PY "$lc_copy2/bin/orch" --help 2>&1)
lc_key1=$(lc_key "$lc_cache3")
contains "$out" "EXTRA-PART-RAN" "a new part runs"
[[ -n "$lc_key0" && -n "$lc_key1" && "$lc_key1" != "$lc_key0" ]] && ok "adding a part changes the key, so the cache is rewritten" \
  || bad "adding a part did not change the key ($lc_key0 / $lc_key1)"
mv "$lc_copy2/lib/orch_core/01-extra.py" "$lc_copy2/lib/orch_core/01-aaa.py"
out=$(ORCH_HOME="$lc_home3" $PY "$lc_copy2/bin/orch" --help 2>&1)
lc_key2=$(lc_key "$lc_cache3")
contains "$out" "EXTRA-PART-RAN" "a renamed part still runs"
[[ -n "$lc_key2" && "$lc_key2" != "$lc_key1" ]] && ok "renaming a part changes the key" || bad "renaming a part did not change the key"
rm -f "$lc_copy2/lib/orch_core/01-aaa.py"
out=$(ORCH_HOME="$lc_home3" $PY "$lc_copy2/bin/orch" --help 2>&1)
lc_key3=$(lc_key "$lc_cache3")
lacks "$out" "EXTRA-PART-RAN" "a removed part no longer runs"
[[ -n "$lc_key3" && "$lc_key3" == "$lc_key0" ]] && ok "removing the part restores the original key" || bad "removing a part did not restore the key"
# a copy with no parts: a clear message and exit 1
lc_copy3="$T/plugin-empty"
mkdir -p "$lc_copy3/bin" "$lc_copy3/lib/orch_core"
cp "$PLUGIN/bin/orch" "$lc_copy3/bin/orch"
out=$(ORCH_HOME="$(native "$T/cache-home-4")" $PY "$lc_copy3/bin/orch" --help 2>&1); rc=$?
expect_rc 1 $rc "a plugin copy with no parts"
contains "$out" "no code parts" "…says why"
# a corrupt cache: ignored, rewritten for these parts, and the call still succeeds
printf 'not a bytecode cache' > "$lc_cache"
ORCH_HOME="$lc_home" $ORCH --help >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "a corrupt cache does not break the call" || bad "a corrupt cache broke the call: rc=$rc"
$PY - "$(native "$PLUGIN/lib/orch_core")" "$(native "$lc_cache")" <<'EOF' && ok "a corrupt cache is rewritten for these parts" || bad "the corrupt cache was not rewritten"
import hashlib, os, re, sys
d, cache = sys.argv[1], sys.argv[2]
digest = hashlib.sha256()
for name in sorted(os.listdir(d)):
    path = os.path.join(d, name)
    if not (re.match(r"[0-9][0-9]-[^/\\]+\.py$", name) and os.path.isfile(path)):
        continue
    with open(path, "rb") as fh:
        source = fh.read()
    digest.update(name.encode("utf-8") + b"\0" + source + b"\0")
digest.update(sys.version.encode("utf-8", "replace"))
key = digest.digest()
with open(cache, "rb") as fh:
    data = fh.read()
assert data[:len(key)] == key and len(data) > len(key)
EOF
# an ORCH_HOME that cannot be created (a regular file is in its place) only means no cache
lc_bad="$(native "$T/home-is-a-file")"
printf '' > "$lc_bad"
ORCH_HOME="$lc_bad" $ORCH --help >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "an ORCH_HOME that cannot be created still runs orch" || bad "an uncreatable ORCH_HOME broke the call: rc=$rc"
# python -B writes no cache
lc_homeB="$(native "$T/cache-home-B")"
mkdir -p "$lc_homeB"
ORCH_HOME="$lc_homeB" $PY -B "$PLUGIN/bin/orch" --help >/dev/null 2>&1
[[ -e "$lc_homeB/.pycache" ]] && bad "python -B wrote a cache" || ok "python -B writes no cache"
# the parts, concatenated in file-name order, parse as one Python file: no part depends on a particular cut
$PY -B - "$(native "$PLUGIN/lib/orch_core")" <<'EOF' && ok "the parts concatenated parse as one Python file" || bad "the parts do not concatenate into one Python file"
import os, re, sys
d = sys.argv[1]
names = sorted(n for n in os.listdir(d)
               if re.match(r"[0-9][0-9]-[^/\\]+\.py$", n) and os.path.isfile(os.path.join(d, n)))
assert names, "no parts in %s" % d
source = "".join(open(os.path.join(d, n), "rb").read().decode("utf-8") for n in names)
compile(source, "orch_core_joined", "exec")
EOF
# loaded as a module (SourceFileLoader), bin/orch still exposes the real functions; a patch on one reaches them
$PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$PLUGIN")" <<'EOF' && ok "a module loaded from bin/orch keeps the real functions, patches reach them" || bad "the loaded module is not the real one"
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("orch_under_test", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch_under_test", loader))
loader.exec_module(m)
name = lambda f: f.__code__.co_filename.replace("\\", "/")
assert name(m.iso).endswith("lib/orch_core/01-helpers.py"), name(m.iso)
assert name(m.main).endswith("lib/orch_core/28-argparse.py"), name(m.main)
assert os.path.normcase(os.path.realpath(str(m.PLUGIN_ROOT))) == os.path.normcase(os.path.realpath(sys.argv[2])), m.PLUGIN_ROOT
m.cmd_status = lambda a: 42
assert m.main(["status"]) == 42
EOF
