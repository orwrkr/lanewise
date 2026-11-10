echo "── worktree"
out=$($ORCH worktree add feat-x); contains "$out" "proj.wt/feat-x" "worktree created next to repo"
git -C "$REPO" branch | grep -q "orch/feat-x" && ok "branch orch/feat-x" || bad "branch missing"
grep -q ".lanewise/" "$REPO/.git/info/exclude" && ok ".lanewise/ excluded from git" || bad "exclude missing"

