echo "── launcher: compiled once, cached bytecode"
lc_home="$(native "$T/cache-home")"
lc_tag=$($PY -c "import sys; print(sys.implementation.cache_tag or '')" 2>/dev/null)
[[ -n "$lc_tag" ]] && ok "the interpreter has a cache tag ($lc_tag)" || bad "no cache tag from the interpreter"
lc_cache="$lc_home/.pycache/orch_core.$lc_tag.bin"
ORCH_HOME="$lc_home" $ORCH --help >/dev/null 2>&1
[[ -f "$lc_cache" ]] && ok "a first orch call writes the bytecode cache" || bad "no cache file: $lc_cache"
# the cache is a key (a sha256 digest, 32 bytes) followed by marshal.dumps(code): keep the key, swap the code
$PY - "$(native "$lc_cache")" <<'EOF' && ok "a second call runs the code from the cache" || bad "the cached code was not used"
import marshal, sys
with open(sys.argv[1], "rb") as fh:
    key = fh.read()[:32]
with open(sys.argv[1], "wb") as fh:
    fh.write(key + marshal.dumps(compile('print("CACHE-PAYLOAD-RAN")', sys.argv[1], "exec")))
EOF
out=$(ORCH_HOME="$lc_home" $ORCH --help 2>&1)
contains "$out" "CACHE-PAYLOAD-RAN" "a second call runs the cached code"
rm -f "$lc_cache"
# another copy of the plugin, same ORCH_HOME layout: an edited source is compiled again, not served from the cache
lc_copy="$T/plugin-copy"
mkdir -p "$lc_copy/bin" "$lc_copy/lib"
cp "$PLUGIN/bin/orch" "$lc_copy/bin/orch"
cp "$PLUGIN/lib/orch_core.py" "$lc_copy/lib/orch_core.py"
lc_home2="$(native "$T/cache-home-2")"
ORCH_HOME="$lc_home2" $PY "$lc_copy/bin/orch" --help >/dev/null 2>&1
[[ -f "$lc_home2/.pycache/orch_core.$lc_tag.bin" ]] && ok "a copied plugin writes its cache too" || bad "the copied plugin wrote no cache"
$PY - "$(native "$lc_copy/lib/orch_core.py")" <<'EOF' || bad "cannot edit the copied source"
import sys
with open(sys.argv[1], "rb") as fh:
    source = fh.read()
with open(sys.argv[1], "wb") as fh:
    fh.write(b'print("FRESH-SOURCE-RAN")\n' + source)
EOF
out=$(ORCH_HOME="$lc_home2" $PY "$lc_copy/bin/orch" --help 2>&1)
contains "$out" "FRESH-SOURCE-RAN" "a changed source is compiled again, not served from the old cache"
# a corrupt cache: ignored, rewritten for this source, and the call still succeeds
printf 'not a bytecode cache' > "$lc_cache"
ORCH_HOME="$lc_home" $ORCH --help >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "a corrupt cache does not break the call" || bad "a corrupt cache broke the call: rc=$rc"
$PY - "$(native "$PLUGIN/lib/orch_core.py")" "$(native "$lc_cache")" <<'EOF' && ok "a corrupt cache is rewritten for this source" || bad "the corrupt cache was not rewritten"
import hashlib, sys
with open(sys.argv[1], "rb") as fh:
    source = fh.read()
with open(sys.argv[2], "rb") as fh:
    data = fh.read()
key = hashlib.sha256(source + sys.version.encode("utf-8", "replace")).digest()
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
# loaded as a module (SourceFileLoader), bin/orch still exposes the real functions; a patch on one reaches them
$PY -B - "$(native "$PLUGIN/bin/orch")" "$(native "$PLUGIN")" <<'EOF' && ok "a module loaded from bin/orch keeps the real functions, patches reach them" || bad "the loaded module is not the real one"
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("orch_under_test", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch_under_test", loader))
loader.exec_module(m)
assert m.main.__code__.co_filename.replace("\\", "/").endswith("lib/orch_core.py"), m.main.__code__.co_filename
assert os.path.normcase(os.path.realpath(str(m.PLUGIN_ROOT))) == os.path.normcase(os.path.realpath(sys.argv[2])), m.PLUGIN_ROOT
m.cmd_status = lambda a: 42
assert m.main(["status"]) == 42
EOF

