# Findings (November 2026)

## Update, 5 Nov 2026: every helper mode failed on real work, and the fixes
A real session with a ~350-line Python file got timeouts or no output from every mode. Tiny prompts still worked, so the problems only showed up at real size.

| Symptom | Cause | Fix in the wrappers |
|---|---|---|
| Grok review/code timed out at 5–15 min with no answer or edits | `--permission-mode plan` puts Grok into its planning workflow in a real repo: `enter_plan_mode`, then `ask_user_question` (never answered headless), then a plan file. Separately, grok-4.7, 4.6 and 4.7-build-fast reasoned for 10+ min on a 350-line review; `--reasoning-effort low` didn't help | No plan mode. Read-only runs get `--tools read_file,grep,list_dir`; worktrees add `search_replace,write` plus the scoped `Edit(...)` rule. Also `--no-plan --no-subagents --disable-web-search`. Default model **grok-4.5** (review in 2–3 min). Limits 10 min, or 15 min for code |
| Grok explored the whole repo for a piped review | It follows the repo's CLAUDE.md ("read SPEC.md first"), reads tests and so on, which is slow at its speed | Piped input without `--cwd` runs in an empty folder |
| agy review: no events for 5 min, then a timeout | agy 1.5.1 (auto-updated from 1.4.12) with Flash-**high** never finished; Flash-medium used 63K thinking tokens and took 7 min | Default **gemini-3.8-flash-low** (20–30 s); `--effort medium/high` is opt-in |
| agy raw "say ok" in plan mode wrote `plan.md` and asked to "Proceed" | agy 1.5 plan mode turns some prompts into an implementation plan | The wrapper's "answer as text" preamble avoids it; a plan reply is reported as `HELPER_ERROR` |
| agy worktree: `no output produced — a tool required the "read_file"/"command" permission` | A denied tool ends a headless agy turn with no output. It tried to read the repo venv (git-ignored, so outside the worktree) and to run `git diff` | Read-only `git diff/status/log/show` pre-allowed via `--settings`; the prompt says shell is blocked, don't run tests, don't look for venvs |
| Error text ended in `(e.g. )` | The wrapper cut the message at 200 characters, then added its own `)` | Cut at 400 characters, marked with `...` |
| Nothing to debug afterwards | No logs | Every run keeps `~/.cache/ask-helpers/runs/<time>-<helper>-<task>/` (prompt, raw stream, run.txt), and failures print `LOG:`. The last 30 runs are kept |

Other notes:
- A Grok run that streams nothing for 180 s is stopped as `stuck` (the watchdog). Grok's `streaming-json` emits a `thought` every few words, so slow is distinguishable from stuck. agy streams no thinking, so for agy only the overall timeout applies.
- **Timeouts are not remembered** as unavailable: they depend on the task, not on the account. `--status` shows the last run's result instead.
- `helper-smoke` checks both helpers end to end (a tiny review plus a worktree task that must produce a one-file diff) in under 2 minutes.
- Verified after the fixes: the 350-line review took 137 s with Grok and 32 s with Gemini. A real worktree task (unify KB units and add tests) took 47 s with Grok and 63 s with Gemini, and both branches passed the repo's own unittests.

These are things we found while building this on Windows 11. Each was verified by running the tool, unless it says otherwise. The CLIs change often, so re-check before relying on any of this.

## Gemini CLI no longer works with consumer plans
- Since 18 June 2026, "Sign in with Google" in Gemini CLI fails for Google AI Pro, Ultra and free accounts with:
  `This client is no longer supported for Gemini Code Assist for individuals ... migrate to the Antigravity suite`
- Gemini CLI still works with paid API keys and enterprise Code Assist licences only.
- The consumer successor is the **Antigravity CLI (`agy`)**. It installs with Google Antigravity at `~/.gemini/bin/agy.exe` on Windows.
- On Google AI Pro in our test, agy offered only **Gemini 3.8 Flash** (low/medium/high). The Pro model was not selectable, so reviews default to Grok and Flash is the labelled backup.
- agy's quota comes in two windows, a **weekly limit and a 5-hour limit**, shared by Gemini Flash and Pro. Claude and GPT models in agy have a separate quota.

## agy headless behaviour
- Run it as `agy -p "..." --output-format json --model ID --print-timeout 300s`. The JSON contains `status`, `response`, `error`, `finished_reason` and `usage`, **but not the model that answered**. Pass `--model` explicitly; headless mode refuses unknown models with exit 1 instead of falling back.
- ⚠️ A **timeout reports `status:"SUCCESS"` with exit 0**, plus `finished_reason:"print_timeout"` and an empty response. Check `finished_reason`.
- Even "hi" costs about 7 K input tokens of built-in agent prompt, and calls take 10–70 s.
- Headless mode cannot prompt for permissions. A tool that needs approval is soft-denied, and the run can end with **no output at all**. Telling the model "do not run shell commands, reply with text" fixed this.
- `--mode plan` kept agy read-only. `--mode accept-edits` allowed edits in the working folder, while reads and writes outside it were denied by default.
- **`useG1Credits` (paid-credit overflow) can't be stored as `false` in settings.json.** agy marks the key `omitempty`, so it deletes `false` and a missing key means off. To be sure, the wrapper passes `--settings '{"useG1Credits":false}'` on every call. agy also rewrites settings.json when an interactive session exits, so edit it only while agy is closed.
- One agy run sat for 10 minutes in a very long temp folder path. Short paths are fine.

## Grok Build (`grok`) behaviour
- Windows install: `irm https://x.ai/cli/install.ps1 | iex`. It puts `grok.exe` and `agent.exe` in `~/.grok/bin`, adds that folder to the user PATH, and bundles its own MinGit.
- **X Plus is accepted for Grok Build,** but usage is a **single weekly pool shared with Grok chat, Imagine and Cursor**. When it is spent, every call fails with
  `API error (status 402 Payment Required): Grok Build usage balance exhausted`. That is the plan quota, not a billing problem. Keep paid credits at $0 and auto top-up off.
- Run it as `grok -p "..." --output-format plain|json -m MODEL --cwd DIR`. Errors are exit 1, with `{"type":"error","message":...}` on stdout and the same text on stderr.
- `--permission-mode plan` kept Grok read-only.
- ⚠️ **Edits in headless mode:**
  - `--permission-mode acceptEdits` still refused edits ("a headless run cannot ask for approval").
  - `--permission-mode auto` allowed edits **and ran shell commands**.
  - Unscoped `--allow Edit --allow Write` let Grok write **outside the working folder**.
  - `--sandbox workspace` did **not** stop that on Windows; the docs only describe Linux/macOS enforcement.
  - **What worked:** `--permission-mode default --allow "Edit(C:/path/to/worktree/**)"`. Edits and new files inside were allowed, writes outside were denied, and shell commands were denied.

## Windows traps
- **A new PATH needs a full app restart.** The Claude desktop app's shells inherit PATH from when the app started. Closing the window is not enough; quit it from the tray. The `ask-grok` wrapper also adds `~/.grok/bin` to PATH itself.
- **PowerShell blocks npm's `.ps1` shims** by default (`running scripts is disabled on this system`). Use the `.cmd` shim, Git Bash, or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **MSYS rewrites `/paths` in arguments** passed to native `.exe` files, which can mangle prompts. The wrappers set `MSYS_NO_PATHCONV=1` and convert their own paths with `cygpath`.
- **A Windows command line maxes out near 32 K characters.** The wrappers send prompts over 24 KB through a file.
- Claude Code's Bash tool on Windows is Git Bash, so the wrappers are Bash. A PowerShell session can call them via `bash`.

## Claude Code side
- Merging `Bash(ask-gemini:*)`, `Bash(ask-grok:*)` and `Bash(git diff:*)` into `permissions.allow` stops the prompts. Piped commands are checked part by part.
- Keep secrets out of `settings.json` allow-rules. An approved command that contains a token gets saved there in plain text.
- With the desktop app's Remote Control ("Let your phone and claude.ai start sessions here" + "Keep this computer awake"), phone sessions run on the PC, so the wrappers and local HANDOFF.md notes work from your phone. Cloud sessions that run from GitHub can't use them.
