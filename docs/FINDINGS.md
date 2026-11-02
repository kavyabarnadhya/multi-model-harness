# Findings (November 2026)

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
