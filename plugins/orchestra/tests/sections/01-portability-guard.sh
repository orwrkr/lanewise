echo "── portability guard (no machine-specific content)"
GUARD="$(native "$PLUGIN/tests/check_portable.py")"
ROOT_REPO="$(cd "$PLUGIN/../.." && pwd)"
out=$($PY "$GUARD" --root "$(native "$ROOT_REPO")" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "the repository itself is clean" || { bad "machine-specific content in the repository"; echo "$out"; }
GT="$T/guard"; mkdir -p "$GT" || die "cannot create guard repository"
git -C "$GT" init -q && git -C "$GT" config user.email t@t.invalid && git -C "$GT" config user.name t || die "guard repository"
guard_on() { printf '%s\n' "$1" > "$GT/f.txt"; $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1; }
u=someone     # the paths are assembled here, so this file stays clean for the guard
for text in "C:/Users/$u/x" 'C:\Users\'"$u"'\x' "C:\\\\Users\\\\$u\\\\x" "/c/Users/$u/x" "/mnt/c/Users/$u/x" "/home/$u/x" "/Users/$u/x" \
            "D:/$u/x" "/mnt/d/$u/x"; do
  guard_on "see $text here" && bad "guard missed: $text" || ok "guard flags: $text"
done
for text in "C:/Users/me/x" "/home/you/x" "/path/to/x" 'C:\path\to\x' "https://github.com/x/home/y" '$T/home/z' '~/.orchestra' \
            'STATUS:\s*' "C:/Users/Public/x" 'C:\Program Files\Git' '$HOME/.local' '"C:\\"'; do
  guard_on "see $text here" && ok "guard allows: $text" || bad "guard false alarm: $text"
done
guard_on "see C:\Program Files\Git here" && ok "guard allows a system path with a space" || bad "guard false alarm on a system path"
GW="$T/guard-nogit"; mkdir -p "$GW/sub" || die "cannot create guard directory"; printf 'gitdir: /nowhere\n' > "$GW/.git"
printf 'x /home/%s/y\n' "$u" > "$GW/sub/f.txt"
$PY "$GUARD" --root "$(native "$GW")" >/dev/null 2>&1 && bad "guard passed a tree git can't read" || ok "guard still scans a worktree git can't read"
printf 'a zzguardname b\n' > "$GT/f.txt"
USER=zzguardname USERNAME=zzguardname LOGNAME=zzguardname $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1 \
  && bad "guard missed this machine's user name" || ok "guard flags this machine's user name"
$PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1 && ok "another name is no finding" || bad "guard flagged a name that isn't this machine's"
printf 'x /home/%s/y\n' "$u" > "$GT/f.txt"; git -C "$GT" add f.txt; printf 'clean\n' > "$GT/f.txt"
( cd "$GT" && $PY "$GUARD" --staged >/dev/null 2>&1 ) && bad "guard --staged missed the index" || ok "guard --staged reads the index, not the file"
printf 'clean\n' > "$GT/f.txt"; git -C "$GT" add f.txt
printf 'subject\n\n/home/%s/y\n' "$u" > "$GT/msg"
$PY "$GUARD" --message "$(native "$GT/msg")" >/dev/null 2>&1 && bad "guard missed a commit message" || ok "guard flags a commit message"
printf 'subject\n# /home/%s/y\n' "$u" > "$GT/msg"
$PY "$GUARD" --message "$(native "$GT/msg")" >/dev/null 2>&1 && ok "guard skips comment lines in a message" || bad "guard flagged a message comment"
HOOKS="$(native "$ROOT_REPO/.githooks")"
printf 'x /home/%s/y\n' "$u" > "$GT/f.txt"; git -C "$GT" add f.txt
git -C "$GT" -c core.hooksPath="$HOOKS" commit -qm bad >/dev/null 2>&1 && bad "pre-commit let a home path through" || ok "pre-commit stops a home path"
printf 'clean\n' > "$GT/f.txt"; git -C "$GT" add f.txt
# through a file: Git Bash rewrites a `-m /home/…` argument before git ever sees it
printf 'subject /home/%s/y\n' "$u" > "$GT/msg"
git -C "$GT" -c core.hooksPath="$HOOKS" commit -q -F "$(native "$GT/msg")" >/dev/null 2>&1 && bad "commit-msg let a home path through" || ok "commit-msg stops a home path"
git -C "$GT" -c core.hooksPath="$HOOKS" commit -qm "fine" >/dev/null 2>&1 && ok "a clean commit passes both hooks" || bad "hooks stopped a clean commit"
# private names: read at run time from ~/.orchestra, never listed in the repository
rm -f "$GT/msg"    # it holds a home path from above, and this repository is scanned and committed below
GH="$T/guard-home"; mkdir -p "$GH" || die "cannot create guard home"
printf 'Acmecorp\n# a comment\n\n' > "$GH/private_terms.txt"
cat > "$GH/profiles.json" <<'EOF'
{"providers": {"deepseek": {"profiles": {"betacli": {"key": "KEY_OF_GAMMA"}, "personal": {"key": "DEEPSEEK_API_KEY"}}},
               "codex": {"profiles": {"work": {"key": "CODEX_API_KEY_WORK"}}}},
 "projects": {"/path/to/delta-app": {"deepseek": "betacli"}}, "project_rules": {"/path/to/epsilon-app": "rule"}}
EOF
guard_private() { printf '%s\n' "$1" > "$GT/f.txt"; ORCH_HOME="$(native "$GH")" $PY "$GUARD" --root "$(native "$GT")" >/dev/null 2>&1; }
for text in "acmecorp" "ACMECORP-web" "x_acmecorp_y" "deepseek@betacli" "KEY_OF_GAMMA" "delta-app" "epsilon-app"; do
  guard_private "see $text here" && bad "guard missed a private name: $text" || ok "guard flags a private name: $text"
done
for text in "macmecorpx" "personal" "deepseek@personal" "DEEPSEEK_API_KEY" "a comment" "client"; do
  guard_private "see $text here" && ok "guard allows: $text" || bad "guard false alarm on a private name: $text"
done
# a standard key name with a free label names no account: the label is generic, the key is the standard variable
guard_private "see CODEX_API_KEY_WORK here" && ok "a standard key plus a generic label is not a private name" \
  || bad "guard flagged a standard key with a generic label"
printf 'see delta-app here\n' > "$GT/f.txt"
out=$(ORCH_HOME="$(native "$GH")" $PY "$GUARD" --root "$(native "$GT")" 2>&1)
contains "$out" "delta-app (a folder bound in profiles.json)" "the guard names where a private name came from"
guard_on "see acmecorp here" && ok "no ~/.orchestra (CI): no private names to check" || bad "guard flagged a name with no list"
printf 'subject acmecorp\n' > "$T/guard-msg"
ORCH_HOME="$(native "$GH")" $PY "$GUARD" --message "$(native "$T/guard-msg")" >/dev/null 2>&1 && bad "guard missed a private name in a message" || ok "guard flags a private name in a message"
printf '{broken' > "$GH/profiles.json"
guard_private "see acmecorp here" && bad "a broken profiles.json dropped the private terms" || ok "a broken profiles.json leaves the private terms working"
guard_private "see betacli here" && ok "a broken profiles.json is no finding" || bad "guard failed on a broken profiles.json"
# a push: the last stop before commits leave this machine, for what the commit hooks didn't see
GR="$T/guard-remote.git"; git init -q --bare "$GR" || die "cannot create guard remote"
git -C "$GT" remote add origin "$(native "$GR")" || die "guard remote"
git -C "$GT" checkout -q -- f.txt 2>/dev/null
git -C "$GT" add -A; git -C "$GT" -c commit.gpgsign=false commit -qm "clean again" --no-verify >/dev/null 2>&1
gpush() { ORCH_HOME="$(native "$GH")" git -C "$GT" -c core.hooksPath="$HOOKS" push -q origin "$@" >/dev/null 2>&1; }
gcommit() { git -C "$GT" add -A; git -C "$GT" -c commit.gpgsign=false commit -q --no-verify "$@" >/dev/null 2>&1; }
gbranch="$(git -C "$GT" symbolic-ref --short HEAD)"
printf 'acmecorp\n' > "$GT/old.txt"; gcommit -m "an early name"; git -C "$GT" rm -q old.txt; gcommit -m "removed again"
gpush "$gbranch" && bad "pre-push let a name through in an old commit, though the tree is clean" || ok "pre-push reads the whole history a new branch would send"
git -C "$GT" reset -q --hard HEAD~2
gpush "$gbranch" && ok "pre-push lets a clean branch through" || bad "pre-push stopped a clean branch"
gcommit --allow-empty -m "subject acmecorp"
gpush "$gbranch" && bad "pre-push let a private name through in a message" || ok "pre-push stops a private name in a message"
git -C "$GT" reset -q --hard HEAD~1
printf 'x /home/%s/y\n' "$u" > "$GT/f2.txt"; gcommit -m "a home path"
gpush "$gbranch" && bad "pre-push let a home path through" || ok "pre-push stops a home path"
git -C "$GT" reset -q --hard HEAD~1
git -C "$GT" -c tag.gpgsign=false tag -a t1 -m "tag acmecorp"
gpush t1 && bad "pre-push let a private name through in a tag" || ok "pre-push stops a private name in an annotated tag"
git -C "$GT" tag -d t1 >/dev/null
gcommit --allow-empty -m "fine again"
gpush "$gbranch" && ok "pre-push lets the next clean commit through" || bad "pre-push stopped a clean commit"

