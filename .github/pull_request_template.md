## Summary

<!-- What changes, and why. -->

## Test plan

<!-- How this was verified: the commands run and the cases covered. -->

## Checklist

- [ ] The self-test passes (`bash tests/run_tests.sh`) and `claude plugin validate` passes.
- [ ] Behaviour changed: the version is bumped in `plugins/lanewise/.claude-plugin/plugin.json`, and `CHANGELOG.md`
  has an entry.
- [ ] The public documents are still true: `PRIVACY.md`, `TERMS.md`, `SECURITY.md`, the plugin README's "What it
  runs, sends and fetches" and its storage table ("Where things are stored"), and `docs/index.html`.
- [ ] No private names, machine paths or secrets (`tests/check_portable.py`).
