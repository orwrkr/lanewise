#!/usr/bin/env bash
# Self-test for orch: fake codex + fake claude (DeepSeek worker) + temporary git repo + isolated ORCH_HOME.
# Runs in WSL/Linux/macOS and on Windows in Git Bash (native Windows Python).
#
# The preamble is tests/lib.sh; each section is tests/sections/NN-<slug>.sh, sourced in file order into this one
# shell (a section may rely on what an earlier one left, or declare it with a `# needs: NN-slug …` header line).
# Usage: bash tests/run_tests.sh                 everything, in order (what CI runs)
#        bash tests/run_tests.sh --list          the sections: NN-slug  title  (needs: …)
#        bash tests/run_tests.sh <sel>…          only the selected sections and what they need, then the summary
#   <sel> is a number (12), a slug or a unique prefix of one (spend, prices), or a glob over slugs ('session-*').
#   An unknown or ambiguous selector exits 2. ORCH_TEST_TIMING=1 prints how long each check took.
_rt_dir="$(cd "$(dirname "$0")" && pwd)" || { echo "Self-test: cannot locate the tests directory" >&2; exit 2; }
_rt_names=(); _rt_slugs=(); _rt_titles=(); _rt_needs=(); _rt_flagged=0
for _rt_f in "$_rt_dir"/sections/[0-9][0-9]-*.sh; do
  [[ -f $_rt_f ]] || continue
  _rt_n=${_rt_f##*/}; _rt_n=${_rt_n%.sh}
  _rt_t=""; _rt_nd=""
  while IFS= read -r _rt_l || [[ -n $_rt_l ]]; do      # header lines, then the section's title line
    case "$_rt_l" in
      '# needs:'*) _rt_nd="${_rt_nd} ${_rt_l#\# needs:}" ;;
      'echo "── '*) _rt_t=${_rt_l#'echo "── '}; _rt_t=${_rt_t%\"}; break ;;
    esac
  done < "$_rt_f"
  if [[ -z $_rt_t ]]; then echo "Self-test: sections/$_rt_n.sh has no echo \"── <title>\" line" >&2; _rt_flagged=1; continue; fi
  _rt_names+=("$_rt_n"); _rt_slugs+=("${_rt_n#*-}"); _rt_titles+=("$_rt_t")
  _rt_needs+=("${_rt_nd# }")
done
[[ $_rt_flagged -eq 0 ]] || exit 2
[[ ${#_rt_names[@]} -gt 0 ]] || { echo "Self-test: no sections in $_rt_dir/sections" >&2; exit 2; }
_rt_show() {   # _rt_show <index>…: the sections, one per line
  local _rt_i
  for _rt_i in "$@"; do
    printf '%s  %s' "${_rt_names[_rt_i]}" "${_rt_titles[_rt_i]}"
    [[ -n ${_rt_needs[_rt_i]} ]] && printf '  (needs: %s)' "${_rt_needs[_rt_i]}"
    echo
  done
}
_rt_all() { local _rt_i; _rt_all_idx=(); for ((_rt_i = 0; _rt_i < ${#_rt_names[@]}; _rt_i++)); do _rt_all_idx+=("$_rt_i"); done; }
_rt_all
_rt_in=()
if [[ $# -gt 0 ]]; then
  case "$1" in
    --list) _rt_show "${_rt_all_idx[@]}"; exit 0 ;;
    -h|--help) sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  for _rt_sel in "$@"; do
    _rt_hits=(); _rt_kind=one
    if [[ $_rt_sel =~ ^[0-9]+$ ]]; then
      for _rt_i in "${_rt_all_idx[@]}"; do
        [[ $((10#${_rt_names[_rt_i]%%-*})) -eq $((10#$_rt_sel)) ]] && _rt_hits+=("$_rt_i")
      done
    elif [[ $_rt_sel == *[\*\?\[]* ]]; then
      _rt_kind=glob
      for _rt_i in "${_rt_all_idx[@]}"; do
        # shellcheck disable=SC2053
        [[ ${_rt_slugs[_rt_i]} == $_rt_sel || ${_rt_names[_rt_i]} == $_rt_sel ]] && _rt_hits+=("$_rt_i")
      done
    else
      for _rt_i in "${_rt_all_idx[@]}"; do      # an exact slug or name wins over a prefix of another
        [[ ${_rt_slugs[_rt_i]} == "$_rt_sel" || ${_rt_names[_rt_i]} == "$_rt_sel" ]] && _rt_hits+=("$_rt_i")
      done
      if [[ ${#_rt_hits[@]} -eq 0 ]]; then
        for _rt_i in "${_rt_all_idx[@]}"; do
          [[ ${_rt_slugs[_rt_i]} == "$_rt_sel"* ]] && _rt_hits+=("$_rt_i")
        done
      fi
    fi
    if [[ ${#_rt_hits[@]} -eq 0 ]]; then
      echo "Self-test: no section matches '$_rt_sel'. Sections:" >&2; _rt_show "${_rt_all_idx[@]}" >&2; exit 2
    fi
    if [[ $_rt_kind == one && ${#_rt_hits[@]} -gt 1 && ! $_rt_sel =~ ^[0-9]+$ ]]; then
      echo "Self-test: '$_rt_sel' is ambiguous. Matches:" >&2; _rt_show "${_rt_hits[@]}" >&2; exit 2
    fi
    for _rt_i in "${_rt_hits[@]}"; do _rt_in[_rt_i]=1; done
  done
  _rt_grew=1          # add what the selected sections declare to need, until nothing more is added
  while [[ $_rt_grew -eq 1 ]]; do
    _rt_grew=0
    for _rt_i in "${_rt_all_idx[@]}"; do
      [[ -n ${_rt_in[_rt_i]:-} ]] || continue
      for _rt_nd in ${_rt_needs[_rt_i]}; do
        _rt_found=-1
        for _rt_j in "${_rt_all_idx[@]}"; do [[ ${_rt_names[_rt_j]} == "$_rt_nd" ]] && _rt_found=$_rt_j; done
        if [[ $_rt_found -lt 0 ]]; then
          echo "Self-test: ${_rt_names[_rt_i]} needs '$_rt_nd', which is not a section" >&2; exit 2
        fi
        [[ -n ${_rt_in[_rt_found]:-} ]] || { _rt_in[_rt_found]=1; _rt_grew=1; }
      done
    done
  done
fi
_rt_run=()
for _rt_i in "${_rt_all_idx[@]}"; do
  if [[ $# -eq 0 || -n ${_rt_in[_rt_i]:-} ]]; then _rt_run+=("${_rt_names[_rt_i]}"); fi
done
set --        # the sections see no arguments, as in the single script
source "$_rt_dir/lib.sh"
for _rt_s in "${_rt_run[@]}"; do
  source "$_rt_dir/sections/$_rt_s.sh"
done
echo
echo "passed: $pass  failed: $fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
