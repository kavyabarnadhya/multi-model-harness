# multi-model-harness: working rules

- Never push to `main`. Every change goes on a branch (`fix/...`, `docs/...`, `feat/...`) and through a pull request (`gh pr create`). Merge only after the owner says so.
- Before opening a PR that touches `bin/`: run `bash -n` on each shell script, `node --check bin/helper-usage.js`, and `helper-smoke` with the branch's scripts first on PATH (`PATH="$PWD/bin:$PATH" helper-smoke`; it checks both helpers, the `ask-helper` router and `helper-stats`). Put the results in the PR description.
- Test against a throwaway state folder when a change touches the state file or the usage ledger: `HELPER_STATE_DIR=/c/tmp/<name>` (copy `~/.cache/ask-helpers/runs` and `state` in for real data), so the owner's real ledger stays clean.
- Keep the repo free of personal data: no emails, tokens, account names or `C:\Users\<name>` paths. Scan with grep before committing.
- When behaviour, defaults or model choices change, update `docs/FINDINGS.md` and the "Last verified" line in `README.md` (with the current `claude`, `agy` and `grok` versions) in the same PR.
- After a merge, deploy: `cp bin/* ~/bin/ && chmod +x ~/bin/ask-* ~/bin/helper-*`, and copy `templates/CLAUDE.md` to `~/.claude/CLAUDE.md` after checking the live file has no edits the template lacks. Then confirm with `diff`.
- Keep `HANDOFF.md` (git-ignored) current: where the work stands, gotchas, open worktrees.
