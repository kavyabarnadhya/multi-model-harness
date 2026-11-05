# multi-model-harness: working rules

- Never push to `main`. Every change goes on a branch (`fix/...`, `docs/...`, `feat/...`) and through a pull request (`gh pr create`). Merge only after the owner says so.
- Before opening a PR that touches `bin/`: run `bash -n` on each script and `helper-smoke` (both helpers must pass). Put the results in the PR description.
- Keep the repo free of personal data: no emails, tokens, account names or `C:\Users\<name>` paths. Scan with grep before committing.
- When behaviour or model choices change, update `docs/FINDINGS.md` and the "Last verified" date in `README.md` in the same PR.
- The live copies on the maintainer's machine are `~/bin/*` and `~/.claude/CLAUDE.md`; keep `bin/` and `templates/CLAUDE.md` in step with them.
