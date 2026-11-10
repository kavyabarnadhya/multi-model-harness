# multi-model-harness

Use **Claude Code** as the lead agent and let it hand jobs to **Gemini** (through Google's Antigravity CLI, `agy`) and **Grok** (through xAI's Grok Build CLI, `grok`). Every model runs on the subscription you already pay for. There are no API keys and no per-token billing.

Claude stays in charge. The helpers run headless through two small Bash wrappers, `ask-gemini` and `ask-grok`. Claude uses them for code review, for reading large repos and logs, and for writing self-contained code. When a helper is out of quota, Claude falls back to the other helper and then to itself, and tells you in one line.

```
you ──► Claude Code ──┬─► ask-grok   ──► grok -p ...  (X / SuperGrok subscription)
                      ├─► ask-gemini ──► agy -p ...   (Google AI Pro / Ultra)
                      └─► does it itself when both are unavailable
```

> Tested in November 2026 on Windows 11 with Git Bash, Claude Code 2.1, agy 1.4.12 and grok 1.0.70.
> The scripts carry fallbacks for macOS/Linux, but they are **untested** there (`date -d` needs GNU date).
> These CLIs change fast: check [docs/FINDINGS.md](docs/FINDINGS.md) before trusting a flag.

## What you get

| Job | Default | Backup | Both unavailable |
|---|---|---|---|
| Code review / second opinion | Grok | Gemini Flash (labelled as such) | Claude reviews itself |
| Reading a whole repo, long logs or docs | Gemini | Grok | Claude reads it |
| Writing a self-contained piece of code | Grok | Gemini | Claude writes it |

What the wrappers do:
- **Read-only by default.** Gemini runs with `--mode plan` and Grok with `--permission-mode plan`. The helper replies with text and Claude applies any changes.
- **Worktree mode for real code.** `--task code --worktree NAME` lets the helper edit a throwaway branch `helper/NAME` in `~/wt/<repo>-NAME`. The wrapper commits the edits and prints a diff stat. Claude reviews the diff, then squash-merges it or discards it.
- **Unavailability is never silent.** A quota, rate-limit, auth, timeout or wrong-model error prints `HELPER_UNAVAILABLE: <helper> (<reason>)` with exit code 3. Any other failure prints `HELPER_ERROR` with exit code 4.
- **Exhausted helpers are remembered.** Quota is remembered for 5 hours, rate limits for 15 minutes, and auth until `--reset`, so Claude stops retrying them.
- **No paid fallback.** The wrappers clear `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `XAI_API_KEY` and similar before every call, and pass `useG1Credits:false` to agy.

## Requirements

- [Claude Code](https://claude.com/claude-code) on any paid Claude plan. The desktop app makes phone access easy through Remote Control.
- **Gemini:** a Google AI Pro or Ultra plan, and the Antigravity CLI `agy` (installed with Google Antigravity).
  Gemini CLI no longer accepts consumer Google sign-in. See [findings](docs/FINDINGS.md#gemini-cli-no-longer-works-with-consumer-plans).
- **Grok:** a SuperGrok or X Premium+/Plus plan that includes Grok Build, and the `grok` CLI from [x.ai](https://x.ai/cli).
- Git, Bash and Node.js. Node parses agy's JSON output.

Either helper is optional. If you only have one, the fallback rules still work.

## Setup

1. **Install and sign in to each helper interactively once.**
   - Gemini: open Antigravity, or run `agy`, sign in with your Google account, and check that the banner names your plan.
     In `/config`, make sure **Use G1 Credits** is off.
   - Grok on Windows: `irm https://x.ai/cli/install.ps1 | iex`. On macOS/Linux: `curl -fsSL https://x.ai/cli/install.sh | bash`.
     Then run `grok login` and choose the account that holds your subscription. Afterwards, `grok models` should list models.
2. **Install the wrappers.** Use any folder on Git Bash's PATH; `~/bin` is on it by default.
   ```bash
   mkdir -p ~/bin && cp bin/* ~/bin/ && chmod +x ~/bin/ask-gemini ~/bin/ask-grok ~/bin/helper-smoke
   ask-gemini --status && ask-grok --status
   ```
3. **Try a call each:**
   ```bash
   ask-gemini --task read "In one sentence, what is in this folder?"
   git diff | ask-grok --task review "Review this diff. Max 3 bullet points."
   ```
4. **Teach Claude the rules.** Copy [templates/CLAUDE.md](templates/CLAUDE.md) into `~/.claude/CLAUDE.md`, or append it to your existing file. Edit the job table to suit you.
5. **Stop the permission prompts.** Merge [templates/settings-allow.json](templates/settings-allow.json) into `permissions.allow` in `~/.claude/settings.json`.
6. **Optional:** git-ignore progress notes everywhere with `echo HANDOFF.md >> ~/.config/git/ignore`.

New Claude Code sessions pick up the rules. Override them per repo in that repo's CLAUDE.md/AGENTS.md, or per task in your prompt ("use Grok", "no helpers").

## Usage

```
ask-<helper> [--task review|read|code] [--cwd DIR] [--timeout SECONDS] [--model ID] PROMPT...
ask-<helper> --task code --worktree NAME [--cwd REPO] PROMPT...
ask-<helper> --list-worktrees | --discard NAME   [--cwd REPO]
ask-<helper> --status | --reset          (add --effort low|medium|high to change thinking effort)
helper-smoke                                 (end-to-end check of both helpers, under 2 min)
```

- Piped input is appended to the prompt.
- Prompts over 24 KB go through a file, because Windows caps command lines near 32 K characters.
- The first output line names the helper and model, e.g. `[grok: grok-4.5]`.
- Default models: `grok-4.5` and `gemini-3.8-flash-low`. They were the only ones fast enough on real-sized input in testing (see [findings](docs/FINDINGS.md)). Override with `--model`.
- Every run keeps a log in `~/.cache/ask-helpers/runs/`, and a failure prints `LOG: <folder>`. A Grok run that streams nothing for 180 s is stopped as stuck. Run `agy models` and `grok models` to see what your plan offers.

Worktree flow, as Claude follows it from CLAUDE.md:
```bash
ask-grok --task code --worktree add-median "Add median() to calc.py with pytest tests"
#   ... WORKTREE: ~/wt/repo-add-median   BRANCH: helper/add-median   (diff stat)
git diff HEAD...helper/add-median      # review it, and run the tests in the worktree
git merge --squash helper/add-median && git commit -m "Add median (written by Grok helper)"
ask-grok --discard add-median
```

## Safety notes

- **Grok's sandbox is not enforced on Windows,** and its `acceptEdits` mode refuses edits in headless runs. The only setup that kept Grok inside the worktree in testing was a path-scoped rule: `--allow "Edit(<worktree>/**)"` with `--permission-mode default`. Unscoped `--allow Edit` let it write anywhere on disk. The wrapper uses the scoped rule.
- Shell commands stay blocked for both helpers. Claude runs the tests, not the helper.
- Helper output is treated as data, not instructions. The CLAUDE.md template says so, and tells Claude never to send secrets to a helper.

## What we learned

See [docs/FINDINGS.md](docs/FINDINGS.md). It covers the Gemini CLI retirement, agy reporting timeouts as success, Grok's shared weekly usage pool, Windows PATH and execution-policy traps, and more.

## Status

**Last verified: 10 November 2026.** Tested on Windows 11 with Git Bash, Claude Code 2.1.210, agy 1.5.4 and grok 1.0.70.

- **Working:** read, review and code tasks for both helpers; worktree mode; quota, timeout and model-error detection; the 5-hour quota memory.
- **Help wanted: macOS and Linux.** The scripts include fallbacks but haven't been run there. Please open an issue with what you find.
- **Expect drift.** Model names and speeds (agy auto-updates itself), CLI flags and plan limits change often. If a call starts failing, check `agy --help` and `grok --help` against [docs/FINDINGS.md](docs/FINDINGS.md), and send a PR with the date you verified it.

## License

MIT. See [LICENSE](LICENSE).
