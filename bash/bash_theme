#!/usr/bin/env bash
# ~/.bash_theme
#####################################################################
# Bash Theme — Riley Oest (Ayu-inspired, modern dev UX)
#####################################################################
#
# Prompt layout:
#   (base) riley@host ~/path branch          2 staged  3 modified ✨ 🔼2 [5/5 ✅ 1d]
#   $
#
# Left side (PS1): conda env, user@host, path, git branch
# Right side (PROMPT_COMMAND): dirty state, sync, GH Actions
#
# Emoji reference:
#   ✅  All workflows passed        🔼  Ahead (needs push)
#   ❌  Workflow(s) failed          🔽  Behind (needs pull)
#   ⏳  Workflows running           🔄  Diverged (ahead AND behind)
#   ✨  Untracked files
#
# ─── One process per prompt ─────────────────────────────────────────
#
# Everything below is shaped by one measurement. On WSL2 a subshell fork
# costs ~200us, a fork+exec ~440us, and forking `git` ~900us. This prompt
# used to spend roughly fifty processes and 57ms per Enter — of which
# about 1ms was git doing actual work. The cost was never the work, it
# was the forking, so the whole design is arranged to avoid it:
#
#   * ONE `git status --porcelain=v2 --branch` yields branch, staged,
#     modified, untracked, ahead, behind and the commit sha together. It
#     replaced six git invocations and their wc/head/awk pipelines.
#   * PS1 reads VARIABLES (__PS1_GIT, __PS1_CONDA) that PROMPT_COMMAND
#     sets. A `$(...)` in PS1 forks on every single Enter.
#   * The right side's visible width is accumulated as the string is
#     built, so nothing shells out to sed to strip colour or to count
#     double-width emoji afterwards.
#   * The GitHub cache is read with the `read` builtin and timestamped
#     from $EPOCHSECONDS, so displaying it costs no processes at all.
#
# Keep it that way. Anything you add below runs on every prompt, and a
# `$(...)` there is not free.

# ─── Conda ──────────────────────────────────────────────────────────
# Prevent Conda from messing with the prompt colors we built
export CONDA_CHANGEPS1=false

# ─── Palette ────────────────────────────────────────────────────────
# Real ESC bytes rather than the string "\033". Building the prompt from
# actual control characters means `printf '%s'` is enough; the old code
# needed `printf '%b'`, which also expands any backslash that happens to
# be in the data it is printing.
__C_CONDA=$'\033[38;5;141m'
__C_BRANCH=$'\033[38;5;215m'
__C_STAGED=$'\033[38;5;150m'
__C_MODIFIED=$'\033[38;5;203m'
__C_GH=$'\033[38;5;250m'
__C_OFF=$'\033[0m'

# \001 and \002 are what bash's \[ and \] decode to: "readline, the bytes
# between these occupy no columns". They cannot be spelled \[ and \] in
# __PS1_GIT / __PS1_CONDA, because bash decodes backslash escapes in PS1
# *before* it expands the variables — a \[ arriving through a variable
# stays literal and readline never learns the colour is zero-width. That
# was the old bug: ~29 colour bytes counted as visible, so long command
# lines and Ctrl-R recall wrapped in the wrong place.
__NP_ON=$'\001'
__NP_OFF=$'\002'

# ─── Shared time helpers ─────────────────────────────────────────────
# Used by PS1 and by the gh-tui screens for consistent timestamps.

# __parse_iso_epoch <iso_timestamp>
# Converts ISO 8601 timestamp to epoch. Handles GNU + BSD date.
# Normalizes both Z and +00:00 suffixes.
__parse_iso_epoch() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && return 1
  # Normalize +00:00 → Z for BSD date
  iso="${iso%+00:00}Z"
  iso="${iso%%ZZ}Z"
  if date -d "$iso" +%s &>/dev/null 2>&1; then
    date -d "$iso" +%s
  else
    date -jf "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || return 1
  fi
}

# __relative_age <out_var> <epoch> <now_epoch>
# Formats an age as now / 2m / 1h / 3d / 2w into a variable, in pure bash.
# This is the prompt's path, and the reason it exists separately from
# __relative_time: going through that instead costs 1631us per prompt —
# two nested $( ) wrapped around two `date` execs — to produce the exact
# same string this produces in 66us. `printf -v` is bash 3.1+, so no
# version guard is needed.
#
# The local is __ra_secs, not the obvious `age`, because bash locals are
# dynamically scoped: a caller doing `__relative_age age ...` would have
# `printf -v age` land on THIS function's local and vanish on return. The
# ugly prefix is what makes the out-parameter safe to name anything.
__relative_age() {
  local __ra_secs=$(( $3 - $2 ))
  if   (( __ra_secs < 60 ));     then printf -v "$1" "now"
  elif (( __ra_secs < 3600 ));   then printf -v "$1" "%dm" $(( __ra_secs / 60 ))
  elif (( __ra_secs < 86400 ));  then printf -v "$1" "%dh" $(( __ra_secs / 3600 ))
  elif (( __ra_secs < 604800 )); then printf -v "$1" "%dd" $(( __ra_secs / 86400 ))
  else                                printf -v "$1" "%dw" $(( __ra_secs / 604800 ))
  fi
}

# __relative_time <iso_timestamp> [now_epoch]
# Returns: now / 2m / 1h / 3d / 2w
# The ISO-string front door, for callers that are already paying for a
# `gh api` round trip and so cannot care about a `date` fork.
__relative_time() {
  local epoch out
  epoch=$(__parse_iso_epoch "$1") || return
  __relative_age out "$epoch" "${2:-$(date +%s)}"
  printf "%s" "$out"
}

# __duration_str <start_iso> <end_iso>
# Returns: 2m15s / 8s / empty on error
__duration_str() {
  local s_epoch c_epoch
  s_epoch=$(__parse_iso_epoch "$1") || return
  c_epoch=$(__parse_iso_epoch "$2") || return
  if (( c_epoch > s_epoch )); then
    local dur=$(( c_epoch - s_epoch ))
    if (( dur >= 60 )); then
      printf "%dm%ds" $(( dur / 60 )) $(( dur % 60 ))
    else
      printf "%ds" "$dur"
    fi
  fi
}

# __local_time <iso_timestamp>
# Returns HH:MM in system local timezone
__local_time() {
  local epoch
  epoch=$(__parse_iso_epoch "$1") || return
  if date -d "@$epoch" +%H:%M &>/dev/null 2>&1; then
    date -d "@$epoch" +%H:%M
  else
    date -jf "%s" "$epoch" +%H:%M 2>/dev/null
  fi
}

# ─── GitHub Actions (opt-in: export GH_PROMPT=1) ───────────────────
#
# Only displays for repos that HAVE workflows.
# Background refresh every 60s — never blocks prompt.
# Timestamp = when the workflow actually ran (not cache age).
export GH_PROMPT=1

__GH_CACHE_DIR="/tmp/gh_status_cache"
__GH_TTL=60           # seconds before a cached answer is refreshed
__GH_PENDING_TTL=120  # seconds before an unfinished refresh is presumed dead
mkdir -p "$__GH_CACHE_DIR" 2>/dev/null

# Cache file: succeeded|total|symbol|run_epoch|skipped|fetch_epoch
#
# Both timestamps are integers rather than ISO strings, and fetch_epoch
# lives in the file rather than in its mtime. That is what lets the
# display path below run without a single `date` or `stat`.
#
# The key is the commit sha, not $PWD. Check runs belong to a commit, so
# every subdirectory of a repo shares one entry instead of each making its
# own API call, and committing invalidates instantly instead of showing
# the previous commit's verdict for up to a minute. (A fork checked out at
# the same sha as its upstream would share an entry — accepted.)

# __gh_refresh <sha> <cache_file> <pending_file>
# Runs detached from the prompt. Forks as freely as it likes.
__gh_refresh() {
  local sha="$1" cache_file="$2" pending_file="$3"
  local repo result fields

  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  result=$(gh api "repos/${repo}/commits/${sha}/check-runs" 2>/dev/null)

  local total="" succeeded failed running skipped last_iso
  if [[ -n "$result" ]]; then
    # One jq pass. This used to be five invocations parsing the same JSON.
    fields=$(jq -r '
      (.check_runs // []) as $r |
      [ ($r | length),
        ([$r[] | select(.conclusion == "success")] | length),
        ([$r[] | select(.conclusion == "failure")] | length),
        ([$r[] | select(.status == "queued" or .status == "in_progress")] | length),
        ([$r[] | select(.conclusion == "skipped")] | length),
        ($r[0].completed_at // $r[0].started_at // "")
      ] | map(tostring) | join("|")' <<< "$result" 2>/dev/null)
    IFS='|' read -r total succeeded failed running skipped last_iso <<< "$fields"
  fi

  if [[ -n "$total" ]] && (( total > 0 )); then
    local sym="ok"
    (( running > 0 )) && sym="run"
    (( failed > 0 ))  && sym="fail"

    local run_epoch=""
    [[ -n "$last_iso" ]] && run_epoch=$(__parse_iso_epoch "$last_iso")

    printf '%s|%s|%s|%s|%s|%s' \
      "$succeeded" "$total" "$sym" "$run_epoch" "$skipped" "$(date +%s)" \
      > "$cache_file"
  else
    rm -f "$cache_file"
  fi

  # Keyed by sha, so every commit leaves an entry behind. Sweeping here
  # costs nothing; sweeping in the prompt would cost a `find`. -mtime +1
  # rounds down, so it really means "two days or older" — this is garbage
  # collection, not a TTL, and the TTL above is what keeps answers fresh.
  find "$__GH_CACHE_DIR" -type f -mtime +1 -delete 2>/dev/null

  rm -f "$pending_file"
}

# __gh_segment <sha> <now_epoch>
# Sets __gh_out (the rendered segment) and __gh_w (its width in columns).
# Spends no processes: `command -v` and `read` are builtins and the age is
# arithmetic. Only the background refresh it may launch costs anything.
__gh_segment() {
  __gh_out=""
  __gh_w=0

  [[ "$GH_PROMPT" == "1" ]] || return
  local sha="$1" now="$2"
  [[ -n "$sha" ]] || return
  command -v gh &>/dev/null || return
  command -v jq &>/dev/null || return

  local cache_file="${__GH_CACHE_DIR}/${sha}"
  local pending_file="${cache_file}.pending"

  local s="" t="" sym="" run_epoch="" skipped="" fetch_epoch=""
  [[ -f "$cache_file" ]] && IFS='|' read -r s t sym run_epoch skipped fetch_epoch < "$cache_file"

  if (( now - ${fetch_epoch:-0} > __GH_TTL )); then
    # A pending marker whose job died — terminal closed, WSL shut down,
    # SIGKILL — used to freeze this repo's status permanently, because the
    # marker was only ever removed by the job that no longer existed. A
    # trap cannot fix that (SIGKILL runs no traps), so the marker carries
    # the epoch it was written at and anything too old is a corpse.
    # Unreadable or empty counts as too old: the worst case is a duplicate
    # API call, where the worst case of trusting it is freezing forever.
    local pending_epoch=""
    [[ -f "$pending_file" ]] && read -r pending_epoch < "$pending_file"
    case "$pending_epoch" in
      '' | *[!0-9]*) pending_epoch=0 ;;
    esac

    if (( now - pending_epoch > __GH_PENDING_TTL )); then
      printf '%s' "$now" > "$pending_file"
      # Launched from inside a subshell, not as a bare `... & disown`. An
      # interactive shell announces a background job as "[1] 12345" on
      # stderr, and this now runs in the shell itself rather than inside the
      # $( ) that used to wrap the whole function — so the announcement
      # would land in the terminal every time the cache went stale. Job
      # control is off in a subshell, which silences it; the grandchild
      # outlives the subshell and is reparented, so no disown is needed.
      ( __gh_refresh "$sha" "$cache_file" "$pending_file" & )
    fi
  fi

  [[ -n "$s" && -n "$t" ]] || return

  local emoji
  case "$sym" in
    fail) emoji="❌" ;;
    run)  emoji="⏳" ;;
    *)    emoji="✅" ;;
  esac

  local skipped_str=""
  (( ${skipped:-0} > 0 )) && skipped_str=" (${skipped} skipped)"

  local age=""
  [[ -n "$run_epoch" ]] && __relative_age age "$run_epoch" "$now"

  __gh_out="${__C_GH}[${s}/${t} ${emoji}${skipped_str} ${age}]${__C_OFF}"
  # Visible: [ s / t <space> emoji <skipped> <space> age ] — the two
  # brackets, the slash and the two spaces are 5, and the emoji is East
  # Asian Wide, so 2 columns for its 1 character.
  __gh_w=$(( ${#s} + ${#t} + ${#skipped_str} + ${#age} + 7 ))
}

# ─── The prompt ─────────────────────────────────────────────────────
#
# Sets __PS1_CONDA and __PS1_GIT for PS1 to read, then prints the right
# side at the right edge using ANSI cursor positioning (\033[{col}G)
# followed by a carriage return, so PS1 redraws over it from column 0.

__prompt_render() {
  local st line xy ab
  local head="" oid="" staged=0 modified=0 untracked=0 ahead=0 behind=0

  __PS1_CONDA=""
  if [[ -n "$CONDA_DEFAULT_ENV" ]]; then
    __PS1_CONDA="${__NP_ON}${__C_CONDA}${__NP_OFF}(${CONDA_DEFAULT_ENV})${__NP_ON}${__C_OFF}${__NP_OFF} "
  fi

  # Cleared before the git call, not after it: leaving a repo has to drop
  # the branch, and the early return below is the path that does it.
  __PS1_GIT=""

  # The one process this prompt spends. --no-optional-locks keeps it from
  # taking the index lock, so pressing Enter cannot contend with a rebase
  # running in another terminal.
  st=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null) || return

  while IFS= read -r line; do
    case "$line" in
      '# branch.oid '*)  oid="${line#'# branch.oid '}" ;;
      '# branch.head '*) head="${line#'# branch.head '}" ;;
      '# branch.ab '*)   ab="${line#'# branch.ab '}"      # "+2 -3"
                         ahead="${ab%% *}";  ahead="${ahead#+}"
                         behind="${ab##* }"; behind="${behind#-}" ;;
      # 1 = tracked change, 2 = rename/copy. Columns 3-4 are XY: X is the
      # staged state, Y the unstaged one, '.' meaning unchanged. Pre-
      # increment, because (( n++ )) evaluates to 0 the first time and so
      # returns a non-zero status.
      '1 '* | '2 '*)     xy="${line:2:2}"
                         [[ "${xy:0:1}" == . ]] || (( ++staged ))
                         [[ "${xy:1:1}" == . ]] || (( ++modified )) ;;
      '? '*)             untracked=1 ;;
    esac
  done <<< "$st"

  # An unborn branch reports "(initial)" — a placeholder, not a sha, and
  # nothing to ask GitHub about.
  [[ "$oid" == '(initial)' ]] && oid=""
  # porcelain v2 says "(detached)" where the old prompt showed
  # `git rev-parse --short`, which picks its length by ambiguity. Seven is
  # what it returns for repos this size.
  [[ "$head" == '(detached)' ]] && head="${oid:0:7}"

  __PS1_GIT=" ${__NP_ON}${__C_BRANCH}${__NP_OFF}${head}${__NP_ON}${__C_OFF}${__NP_OFF}"

  # Right side, with its visible width accumulated as it is built. Every
  # emoji here is East Asian Wide: one character, two columns.
  local right="" w=0

  if (( staged )); then
    right+="${__C_STAGED}${staged} staged${__C_OFF}  "
    (( w += ${#staged} + 9 ))                      # " staged" + 2 spaces
  fi
  if (( modified )); then
    right+="${__C_MODIFIED}${modified} modified${__C_OFF}  "
    (( w += ${#modified} + 11 ))                   # " modified" + 2 spaces
  fi
  if (( untracked )); then
    right+="✨  "
    (( w += 4 ))
  fi
  if (( ahead && behind )); then
    right+="🔄${ahead}/${behind}  "
    (( w += ${#ahead} + ${#behind} + 5 ))
  elif (( ahead )); then
    right+="🔼${ahead}  "
    (( w += ${#ahead} + 4 ))
  elif (( behind )); then
    right+="🔽${behind}  "
    (( w += ${#behind} + 4 ))
  fi

  local now
  # $EPOCHSECONDS is a bash 5 builtin; macOS /bin/bash is 3.2.
  if (( BASH_VERSINFO[0] >= 5 )); then now="$EPOCHSECONDS"; else now=$(date +%s); fi

  __gh_segment "$oid" "$now"
  right+="$__gh_out"
  (( w += __gh_w ))

  # $COLUMNS is maintained by bash itself (bashrc sets `shopt -s
  # checkwinsize`), which is why this does not shell out to `tput cols`.
  local cols="${COLUMNS:-80}"
  if (( w > 0 && w < cols )); then
    printf '\033[%dG%s\r' $(( cols - w )) "$right"
  fi
  return 0
}

# PS1: left side + second line
# Branch is on the left after the path. White dollar sign.
#
# Single-quoted, so ${__PS1_CONDA} and ${__PS1_GIT} are expanded at prompt
# time rather than right now. That is safe against hostile branch names:
# bash does not re-expand the result of a parameter expansion, so a branch
# called `$(rm -rf ~)` renders as those literal characters.
PS1='${__PS1_CONDA}\[\033[38;5;75m\]\u@\h\[\033[0m\] \[\033[38;5;110m\]\w\[\033[0m\]${__PS1_GIT}\n\$ '

# Append, do not assign. `zoxide init bash` — sourced later, from
# bash_productivity — appends __zoxide_hook here, and that hook is the
# only thing that teaches `z` where you have been. A plain
# `PROMPT_COMMAND=` throws it away silently: no error, `z` simply stops
# learning. That works today only because bashrc happens to source this
# file first, which nothing states and nothing enforces. The guard is
# zoxide's own, so `reload` re-sourcing into a live shell stays idempotent.
case ";${PROMPT_COMMAND};" in
  *";__prompt_render;"*) : ;;
  *) PROMPT_COMMAND="__prompt_render${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
esac

# ─── LS_COLORS (Ayu palette) ──────────────────────────────────────
export LS_COLORS="\
di=1;38;5;75:\
ln=38;5;110:\
so=38;5;141:\
pi=38;5;141:\
ex=38;5;150:\
bd=38;5;215:\
cd=38;5;215:\
su=38;5;203:\
sg=38;5;203:\
tw=38;5;214:\
ow=38;5;214:\
*.py=38;5;214:\
*.lua=38;5;75:\
*.js=38;5;215:\
*.ts=38;5;215:\
*.jsx=38;5;215:\
*.tsx=38;5;215:\
*.cs=38;5;75:\
*.json=38;5;180:\
*.yaml=38;5;180:\
*.yml=38;5;180:\
*.toml=38;5;180:\
*.md=38;5;110:\
*.sh=38;5;150:\
*.bash=38;5;150:\
*.css=38;5;110:\
*.html=38;5;203:\
*.sql=38;5;75:\
*.xml=38;5;110:\
*.gitignore=38;5;243:\
*.env=38;5;243:\
*.log=38;5;243:\
*.tar=38;5;203:\
*.gz=38;5;203:\
*.zip=38;5;203:\
*.7z=38;5;203:\
"
export EZA_COLORS="$LS_COLORS"

# ─── Grep colors ──────────────────────────────────────────────────
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# ─── Man page colors ──────────────────────────────────────────────
export LESS='-R'
export LESS_TERMCAP_mb=$'\e[38;5;203m'
export LESS_TERMCAP_md=$'\e[38;5;75m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_so=$'\e[38;5;215;48;5;236m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_us=$'\e[38;5;110m'
export LESS_TERMCAP_ue=$'\e[0m'

# ─── Git / GCC ────────────────────────────────────────────────────
export GIT_PAGER='less -FRX'
export GCC_COLORS='error=01;38;5;203:warning=01;38;5;215:note=01;38;5;110:caret=01;38;5;75:locus=01:quote=01'

#####################################################################
# End Theme
#####################################################################
