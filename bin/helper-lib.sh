# helper-lib.sh: shared code for ask-gemini / ask-grok. Sourced, not run.
# Callers set HELPER (gemini|grok) and define usage() before sourcing.

# Outside Git Bash on Windows there is no cygpath; paths are already native, so pass them through.
command -v cygpath > /dev/null || cygpath() { printf '%s\n' "${@: -1}"; }

HELPER_STATE_DIR="${HELPER_STATE_DIR:-$HOME/.cache/ask-helpers}"
HELPER_STATE_FILE="$HELPER_STATE_DIR/state"
HELPER_ARG_LIMIT=24000          # Windows command lines cap near 32K chars; longer prompts go via a file
QUOTA_TTL=$((5 * 3600))
RATE_TTL=$((15 * 60))
AUTH_TTL=$((365 * 24 * 3600))   # effectively "until --reset"

IDLE_LIMIT=${HELPER_IDLE_LIMIT:-180}   # seconds with no helper output before the run counts as stuck
RUNS_KEPT=30

die_unavailable() { wt_abort; echo "HELPER_UNAVAILABLE: $HELPER ($1)"; log_hint; exit 3; }
die_error()       { wt_abort; echo "HELPER_ERROR: $HELPER ($1)"; log_hint; exit 4; }
log_hint() { [ -n "${work:-}" ] && [ -d "$work" ] && echo "LOG: $(cygpath -w "$work")"; }
# A failed run must not leave a half-made worktree behind.
wt_abort() { [ -n "${WT_CREATED:-}" ] && { WT_CREATED=""; wt_remove; }; }

# Never let a helper fall back to paid API billing; stop MSYS rewriting /paths inside prompts.
sanitize_env() {
  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI GOOGLE_GENAI_USE_GCA \
        GOOGLE_CLOUD_PROJECT GOOGLE_APPLICATION_CREDENTIALS \
        XAI_API_KEY GROK_API_KEY GROK_DEPLOYMENT_KEY
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
}

# --- state file: one line per helper, "<helper> <until-epoch> <reason>" ---

state_get() {
  [ -f "$HELPER_STATE_FILE" ] || return 1
  awk -v h="$HELPER" -v now="$(date +%s)" \
    '$1 == h && $2 > now { print $2, $3; found = 1 } END { exit !found }' "$HELPER_STATE_FILE"
}

state_clear() {
  [ -f "$HELPER_STATE_FILE" ] || return 0
  grep -v "^$HELPER " "$HELPER_STATE_FILE" > "$HELPER_STATE_FILE.tmp"
  mv -f "$HELPER_STATE_FILE.tmp" "$HELPER_STATE_FILE"
}

state_set() { # <seconds> <reason>
  mkdir -p "$HELPER_STATE_DIR"
  state_clear
  echo "$HELPER $(( $(date +%s) + $1 )) $2" >> "$HELPER_STATE_FILE"
}

check_remembered() {
  local line until reason
  line=$(state_get) || return 0
  read -r until reason <<< "$line"
  if [ "$reason" = auth ]; then
    die_unavailable "remembered: auth, sign in again then run: ask-$HELPER --reset"
  fi
  die_unavailable "remembered: $reason, until $(date -d "@$until" +%H:%M)"
}

# --- failure classification ---

classify_failure() { # <text> -> quota|rate-limit|auth|model-unavailable|""
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    *"usage balance exhausted"*|*"balance is too low"*|*quota*|*resource_exhausted*|*"usage limit"*|\
    *"weekly limit"*|*"five hour limit"*|*"limit reached"*|*"payment required"*|*"status 402"*)
      echo quota ;;
    *"status 429"*|*" 429"*|*"rate limit"*|*"rate-limit"*|*ratelimit*|*"too many requests"*)
      echo rate-limit ;;
    *"authentication required"*|*"not authenticated"*|*unauthorized*|*"status 401"*|*"status 403"*|\
    *"please log in"*|*"please sign in"*|*"login required"*|*"token expired"*|*"token has expired"*|*"grok login"*)
      echo auth ;;
    *"not recognized as a known model"*|*"unknown model"*|*"invalid model"*)
      echo model-unavailable ;;
  esac
}

handle_failure() { # <all output> <one-line detail>
  local reason
  reason=$(classify_failure "$1")
  case "$reason" in
    quota)      state_set "$QUOTA_TTL" quota;      die_unavailable quota ;;
    rate-limit) state_set "$RATE_TTL" rate-limit;  die_unavailable rate-limit ;;
    auth)       state_set "$AUTH_TTL" auth;        die_unavailable auth ;;
    model-unavailable) die_unavailable "model-unavailable: $MODEL" ;;
    *)          die_error "$(short_detail "$2")" ;;
  esac
}

# --- run logs and the stuck-run watchdog ---

# Each run keeps its prompt, raw output and result in its own folder, so a failure can be inspected.
new_run_dir() {
  local runs="$HELPER_STATE_DIR/runs"
  mkdir -p "$runs"
  work="$runs/$(date +%Y%m%d-%H%M%S)-$HELPER-$TASK${WORKTREE:+-$WORKTREE}-$$"
  mkdir -p "$work"
  printf '%s' "$PROMPT" > "$work/prompt.txt"
  ls -1d "$runs"/*/ 2> /dev/null | sort | head -n -"$RUNS_KEPT" | while read -r old; do rm -rf "$old"; done
}

run_note() { echo "$(date +%H:%M:%S) $*" >> "$work/run.txt"; }

# run_watched CMD...: stdout -> $work/out, stderr -> $work/err. Stops the run at $TIMEOUT seconds, or
# after $IDLE_LIMIT seconds in which neither file grew. Sets RUN_RC and RUN_END (ok|timeout|stuck).
run_watched() {
  run_note "start: ${*:1:1} (timeout ${TIMEOUT}s, idle limit ${IDLE_LIMIT}s)"
  timeout -k 10 "$TIMEOUT" "$@" < /dev/null > "$work/out" 2> "$work/err" &
  local pid=$! start now last_size size last_change
  start=$(date +%s); last_change=$start; last_size=0
  while kill -0 "$pid" 2> /dev/null; do
    sleep 2
    now=$(date +%s)
    size=$(( $(wc -c < "$work/out") + $(wc -c < "$work/err") ))
    if [ "$size" -ne "$last_size" ]; then last_size=$size; last_change=$now; fi
    if [ $((now - last_change)) -ge "$IDLE_LIMIT" ]; then
      run_note "stuck: no output for ${IDLE_LIMIT}s, stopping"
      kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null
      RUN_RC=124; RUN_END=stuck; return
    fi
  done
  wait "$pid"; RUN_RC=$?
  case $RUN_RC in 124|137) RUN_END=timeout ;; *) RUN_END=ok ;; esac
  run_note "end: rc=$RUN_RC ($RUN_END) after $(( $(date +%s) - start ))s"
}

# One line of error detail; mark a cut with "..." so it never looks like the message ended there.
short_detail() {
  local d
  d=$(printf '%s' "$1" | sed 's/^Error: *//' | tr -s '\r\n' ' ')
  [ ${#d} -gt 400 ] && d="${d:0:400}..."
  printf '%s' "$d"
}

first_line() { cat "$@" 2>/dev/null | grep -m1 -v '^[[:space:]]*$'; }

# --- arguments ---

parse_args() {
  TASK=read; CWD=$PWD; CWD_GIVEN=""; TIMEOUT=""; MODEL=""; EFFORT=""; PROMPT=""; WORKTREE=""
  local action=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)    TASK=$2; shift 2 ;;
      --cwd)     CWD=$2; CWD_GIVEN=1; shift 2 ;;
      --timeout) TIMEOUT=$2; shift 2 ;;
      --model)   MODEL=$2; shift 2 ;;
      --effort)  EFFORT=$2; shift 2 ;;
      --worktree) WORKTREE=$2; shift 2 ;;
      --discard) action=discard; WORKTREE=$2; shift 2 ;;
      --list-worktrees) action=list; shift ;;
      --reset)   state_clear; echo "$HELPER: state cleared"; exit 0 ;;
      --status)
        local line until reason
        if line=$(state_get); then
          read -r until reason <<< "$line"
          echo "$HELPER: unavailable ($reason, until $(date -d "@$until" '+%b %d %H:%M'))"
        else
          echo "$HELPER: available"
        fi
        # Timeouts are not remembered (they depend on the task, not the account), so show the last run too.
        local last
        last=$(ls -1d "$HELPER_STATE_DIR/runs/"*-"$HELPER"-*/ 2> /dev/null | sort | tail -1)
        [ -n "$last" ] && echo "last run: $(basename "$last"): $(grep -E 'end:|stuck:|result:' "$last/run.txt" 2> /dev/null | tail -1 | cut -d' ' -f2-)"
        exit 0 ;;
      -h|--help) usage; exit 0 ;;
      --)        shift; PROMPT="${PROMPT:+$PROMPT }$*"; break ;;
      -*)        die_error "unknown option $1" ;;
      *)         PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
    esac
  done
  case "$TASK" in review|read|code) ;; *) die_error "bad --task '$TASK' (review|read|code)" ;; esac
  # Defaults per helper and task: DEFAULT_TIMEOUT_CODE / DEFAULT_TIMEOUT_OTHER, set by the wrapper.
  [ -z "$TIMEOUT" ] && { [ "$TASK" = code ] && TIMEOUT=${DEFAULT_TIMEOUT_CODE:-600} || TIMEOUT=${DEFAULT_TIMEOUT_OTHER:-300}; }
  case "$TIMEOUT" in *[!0-9]*) die_error "bad --timeout '$TIMEOUT' (seconds)" ;; esac
  case "$EFFORT" in ''|low|medium|high) ;; *) die_error "bad --effort '$EFFORT' (low|medium|high)" ;; esac
  [ -d "$CWD" ] || die_error "no such directory: $CWD"
  CWD=$(cygpath -u "$CWD")
  case "$action" in
    list)    wt_list; exit 0 ;;
    discard) wt_check_name; wt_locate; wt_remove; echo "$HELPER: discarded $WT_BRANCH"; exit 0 ;;
  esac
  if [ -n "$WORKTREE" ]; then
    [ "$TASK" = code ] || die_error "--worktree needs --task code"
    wt_check_name
  fi
  # Append piped or redirected input (e.g. git diff | ask-grok ...); never block on a terminal or /dev/null.
  if [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
    local input
    input=$(cat)
    [ -n "$input" ] && PROMPT="${PROMPT:+$PROMPT$'\n\n'}$input"
    # Piped content without --cwd: answer from it alone. In a repo, helpers otherwise explore it
    # (CLAUDE.md, specs, tests) and a slow model runs out of time.
    if [ -n "$input" ] && [ -z "$CWD_GIVEN" ] && [ -z "$WORKTREE" ]; then
      CWD="$HELPER_STATE_DIR/empty"
      mkdir -p "$CWD"
    fi
  fi
  [ -n "${PROMPT//[[:space:]]/}" ] || die_error "empty prompt"
  # Shell commands are denied in headless runs; without this the helper may try one and return nothing.
  if [ -n "$WORKTREE" ]; then
    PROMPT="You are a coding helper called by another coding agent. Make the requested changes by editing files in the current working directory only; never read or write anywhere else. Shell commands are blocked: do not try to run tests, scripts or installs, and do not look for virtual environments; the calling agent runs the tests afterwards. Start editing early, and when done reply with a short summary of what you changed.

$PROMPT"
  else
    PROMPT="You are a read-only helper called by another coding agent. Do not run shell commands and do not edit files. Answer from the content given; read files in the working directory only when essential. Keep it concise and reply with your full answer as text (include any code in the reply).

$PROMPT"
  fi
}

# --- worktree mode: the helper edits a throwaway branch in its own folder ---

WT_ROOT="${HELPER_WT_ROOT:-$HOME/wt}"   # short path: agy hangs in very long paths

wt_check_name() {
  case "$WORKTREE" in ''|*[!a-z0-9-]*) die_error "worktree name must be lowercase letters, digits, dashes" ;; esac
}

wt_locate() { # sets REPO_ROOT, WT_DIR, WT_BRANCH from CWD and WORKTREE
  REPO_ROOT=$(git -C "$(cygpath -m "$CWD")" rev-parse --show-toplevel 2>/dev/null) || die_error "not a git repo: $CWD"
  REPO_ROOT=$(cygpath -u "$REPO_ROOT")
  WT_DIR="$WT_ROOT/$(basename "$REPO_ROOT")-$WORKTREE"
  WT_BRANCH="helper/$WORKTREE"
}

wt_git() { git -C "$(cygpath -m "$REPO_ROOT")" "$@"; }

wt_setup() { # creates the worktree from HEAD and points CWD at it
  wt_locate
  [ -e "$WT_DIR" ] && die_error "worktree folder already exists: $(cygpath -w "$WT_DIR") (use --discard $WORKTREE)"
  wt_git show-ref --verify --quiet "refs/heads/$WT_BRANCH" && die_error "branch $WT_BRANCH already exists (use --discard $WORKTREE)"
  WT_BASE=$(wt_git rev-parse --short HEAD) || die_error "repo has no commits"
  WT_DIRTY=$(wt_git status --porcelain | head -1)
  mkdir -p "$WT_ROOT"
  wt_git worktree add -q -b "$WT_BRANCH" "$(cygpath -m "$WT_DIR")" HEAD 2> /dev/null \
    || die_error "git worktree add failed for $WT_BRANCH"
  WT_CREATED=1
  CWD=$WT_DIR
}

wt_remove() {
  wt_git worktree remove --force "$(cygpath -m "$WT_DIR")" 2> /dev/null
  rm -rf "$WT_DIR"
  wt_git worktree prune
  wt_git branch -D "$WT_BRANCH" > /dev/null 2>&1
}

wt_finish() { # commits the helper's edits on its branch and prints where they are
  local wt; wt=$(cygpath -m "$WT_DIR")
  git -C "$wt" add -A 2> /dev/null
  if git -C "$wt" diff --cached --quiet; then
    wt_remove
    echo "NO_CHANGES: the helper edited nothing; worktree discarded"
    return
  fi
  git -C "$wt" -c user.name="ask-$HELPER" -c user.email="ask-$HELPER@localhost" \
    commit -q -m "helper($HELPER $MODEL): $WORKTREE" || echo "NOTE: commit failed; changes left uncommitted in the worktree"
  echo "WORKTREE: $(cygpath -w "$WT_DIR")"
  echo "BRANCH: $WT_BRANCH (based on $WT_BASE)"
  [ -n "$WT_DIRTY" ] && echo "NOTE: your main folder had uncommitted changes; the helper did not see them"
  git -C "$wt" diff --stat "$WT_BASE" HEAD
}

wt_list() {
  local root
  root=$(git -C "$(cygpath -m "$CWD")" rev-parse --show-toplevel 2>/dev/null) || die_error "not a git repo: $CWD"
  git -C "$root" worktree list | grep -F '[helper/' || echo "no helper worktrees"
}

usage_common() {
  cat <<EOF
Usage: ask-$HELPER [--task review|read|code] [--cwd DIR] [--timeout SECONDS] [--model ID] PROMPT...
       ask-$HELPER --task code --worktree NAME [--cwd REPO] PROMPT...
       ask-$HELPER --list-worktrees | --discard NAME   [--cwd REPO]
       ask-$HELPER --status | --reset
Piped input is appended to PROMPT. Without --worktree every task is read-only: the answer is printed.
With --worktree the helper edits a new branch helper/NAME in $WT_ROOT/<repo>-NAME (from HEAD); the
wrapper commits its edits and prints WORKTREE, BRANCH and a diff stat. Merge with
git merge --squash helper/NAME, then --discard NAME. A failed run discards the worktree itself.
Exit: 0 answer printed (first line names helper and model)
      3 HELPER_UNAVAILABLE: <helper> (<reason>)   quota, rate-limit, auth, timeout, model-unavailable
      4 HELPER_ERROR: <helper> (<detail>)
EOF
}
