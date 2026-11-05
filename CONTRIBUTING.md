# Contributing

Thanks for helping keep this working. These CLIs change fast, so reports from other machines are the most useful contributions.

## Reporting a problem
Open an issue with:
- OS and shell (Windows Git Bash, macOS, Linux)
- the `agy --version` and `grok --version` output
- the command you ran and the `HELPER_UNAVAILABLE` / `HELPER_ERROR` line
- the relevant part of the run log (`~/.cache/ask-helpers/runs/<run>/run.txt` and the tail of `out`/`err`). **Remove anything private first**: prompts can contain your code.

## Changing the scripts or docs
1. Branch from `main` (`fix/...`, `docs/...`, `feat/...`). Nothing is pushed to `main` directly.
2. Run `bash -n bin/*` and `helper-smoke`, and paste the results into the PR.
3. If behaviour, defaults or model choices change, update `docs/FINDINGS.md` and the "Last verified" line in `README.md`.
4. Open a pull request describing what changed and how you tested it.
