#!/usr/bin/env bash
# ~/.bash_theme
#####################################################################
# Bash Theme — Riley Oest (Ayu-inspired, modern dev UX)
#####################################################################
#
# Prompt layout:
#   (base) riley@host ~/path 🌍 branch 🛡️   2 staged  3 modified  1 untracked  🔼2 [5/5 ✅ 1d]
#   $
#
# Left side (PS1): conda env, user@host, path, repo visibility, git
#                  branch, branch protection
# Right side (PROMPT_COMMAND): dirty state, sync, GH Actions
#
# The three dirty-state counts are words rather than glyphs, and share one
# vocabulary on purpose: they answer the same question at three stages of
# the same pipeline, so `2 staged  3 modified  1 untracked` reads as one
# sentence where a mixed set of emoji and words read as three unrelated
# facts. Untracked counts entries, not files — see where it is rendered.
#
# Emoji reference:
#   ✅  All workflows passed        🔼  Ahead (needs push)
#   ❌  Workflow(s) failed          🔽  Behind (needs pull)
#   ⏳  Workflows running           🌍  Public repo
#   🔒  Private or internal repo    🛡️   Branch has protection rules
#
# Diverged has no glyph of its own: it renders as both arrows at once
# (🔼2  🔽3), which is unmistakable and cannot be read in the wrong order.
# When diverged, `2 conflicting` in bold red says merging those commits
# would conflict, and in how many files. Its ABSENCE means the merge is
# clean — or that the answer is still being computed, for one prompt.
#
# ─── One process per prompt ─────────────────────────────────────────
#
# Everything below is shaped by one measurement. On WSL2 a subshell fork
# costs ~200us, a fork+exec ~440us, and forking `git` ~900us. This prompt
# used to spend roughly fifty processes and ~19ms per Enter — of which
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
# Deliberately the quietest of the three dirty-state colours. Untracked is
# the least urgent of them — green is done, red is in progress, this is
# merely not-yet-git's-problem — and it used to be rendered as ✨, the
# loudest glyph on the line, which had the emphasis exactly backwards.
__C_UNTRACKED=$'\033[38;5;180m'
__C_GH=$'\033[38;5;250m'
__C_WARN=$'\033[38;5;214m'
# The modified red, but bold. A predicted conflict is the same colour
# family as "you have edits" because that is what it is about to become a
# problem for, and it is the loudest thing on the line because it is the
# only state here that costs an afternoon rather than a keystroke.
__C_CONFLICT=$'\033[1;38;5;203m'
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

# ─── Background cache ───────────────────────────────────────────────
#
# Three segments below want an answer too slow to compute on the prompt
# path: CI status (a network round trip), repo visibility and branch
# protection (two more), and whether a diverged pull would conflict (up to
# 11ms of merge). All three want the same shape — show what was last known
# instantly, refresh in a detached job — so the shape lives here once.
#
# It is one place on purpose. The staleness check is easy; the corpse
# check below is not, and it was worth getting wrong once rather than
# three times.
#
# The contract: a producer writes ONE line of |-separated fields whose
# LAST field is the epoch it was written at. Everything before that is the
# producer's own business — this layer only ever reads the timestamp.
# Producers are called as `<fn> <cache_file> [args...]` and must either
# write that file or remove it.

__CACHE_PENDING_TTL=120  # seconds before an unfinished refresh is presumed dead

# __cache_run <dir> <cache_file> <pending_file> <fn> [args...]
# The detached half. Forks as freely as it likes — by the time this runs
# it is already off the prompt path.
__cache_run() {
  local dir="$1" cache_file="$2" pending_file="$3" fn="$4"
  shift 4

  # Made here rather than at source time, where it would fork once in
  # every shell that ever starts to create a directory that outlives the
  # first one. Until it exists the reads simply miss.
  mkdir -p "$dir" 2>/dev/null

  "$fn" "$cache_file" "$@"

  # These caches are keyed, so they accumulate an entry per commit, per
  # branch, per merge. Sweeping here costs nothing; sweeping in the prompt
  # would cost a `find`. -mtime +1 rounds down, so it really means "two
  # days or older" — this is garbage collection, not a TTL, and the TTL is
  # what keeps answers fresh.
  find "$dir" -type f -mtime +1 -delete 2>/dev/null

  rm -f "$pending_file"
}

# __cache_get <dir> <ttl> <key> <now> <fn> [args...]
# Sets __CACHE_FIELDS to the cached line split on |, empty when there is
# no entry yet, and launches <fn> detached when that entry is stale.
# Spends no processes: `read` is a builtin and the age is arithmetic.
#
# The locals carry a __cg_ prefix for the reason __relative_age documents
# above: bash locals are dynamically scoped, so a plainly-named local here
# would shadow a same-named variable in the caller for the duration of the
# call. __CACHE_FIELDS is a global for the same reason — an out-parameter
# naming the caller's variable would have to dodge its own locals.
__cache_get() {
  local __cg_dir="$1" __cg_ttl="$2" __cg_key="$3" __cg_now="$4" __cg_fn="$5"
  shift 5

  local __cg_file="${__cg_dir}/${__cg_key}"
  local __cg_pending="${__cg_file}.pending"

  # Split straight out of the file. Reading the line and splitting it
  # afterwards would want a <<< here-string, and bash implements those
  # with a temporary file — real I/O, on the prompt path, per segment.
  __CACHE_FIELDS=()
  [[ -f "$__cg_file" ]] && IFS='|' read -r -a __CACHE_FIELDS < "$__cg_file"

  # Last field, by the contract above. Spelled with an explicit index
  # rather than [-1], which is bash 4.2+; macOS /bin/bash is 3.2.
  local __cg_n=${#__CACHE_FIELDS[@]} __cg_fetch=0
  (( __cg_n )) && __cg_fetch="${__CACHE_FIELDS[__cg_n-1]}"
  case "$__cg_fetch" in
    '' | *[!0-9]*) __cg_fetch=0 ;;
  esac

  (( __cg_now - __cg_fetch > __cg_ttl )) || return 0

  # A pending marker whose job died — terminal closed, WSL shut down,
  # SIGKILL — used to freeze its entry permanently, because the marker was
  # only ever removed by the job that no longer existed. A trap cannot fix
  # that (SIGKILL runs no traps), so the marker carries the epoch it was
  # written at and anything too old is a corpse. Unreadable or empty
  # counts as too old: the worst case there is a duplicate refresh, where
  # the worst case of trusting it is freezing forever.
  local __cg_pend=""
  [[ -f "$__cg_pending" ]] && read -r __cg_pend < "$__cg_pending"
  case "$__cg_pend" in
    '' | *[!0-9]*) __cg_pend=0 ;;
  esac
  (( __cg_now - __cg_pend > __CACHE_PENDING_TTL )) || return 0

  # 2>/dev/null FIRST: the directory may not exist yet, redirections are
  # applied left to right, and the other order still leaks the failure to
  # the terminal mid-prompt.
  printf '%s' "$__cg_now" 2>/dev/null > "$__cg_pending"

  # Launched from inside a subshell, not as a bare `... & disown`. An
  # interactive shell announces a background job as "[1] 12345" on stderr,
  # and this runs in the shell itself rather than inside a $( ), so the
  # announcement would land in the terminal every time a cache went stale.
  # Job control is off in a subshell, which silences it; the grandchild
  # outlives the subshell and is reparented, so no disown is needed.
  ( __cache_run "$__cg_dir" "$__cg_file" "$__cg_pending" "$__cg_fn" "$@" & )
  return 0
}

# ─── GitHub Actions (opt-in: export GH_PROMPT=1) ───────────────────
#
# Only displays for repos that HAVE workflows.
# Background refresh every 60s — never blocks prompt.
# Timestamp = when the workflow actually ran (not cache age).
export GH_PROMPT=1

__GH_CACHE_DIR="/tmp/gh_status_cache"
__GH_TTL=60           # seconds before a cached answer is refreshed

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

# __gh_refresh <cache_file> <sha>
# A producer for __cache_get: writes the file or removes it, and leaves
# the directory, the sweep and the pending marker to __cache_run.
__gh_refresh() {
  local cache_file="$1" sha="$2"
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

  __cache_get "$__GH_CACHE_DIR" "$__GH_TTL" "$sha" "$now" __gh_refresh "$sha"

  local s="${__CACHE_FIELDS[0]}" t="${__CACHE_FIELDS[1]}" sym="${__CACHE_FIELDS[2]}"
  local run_epoch="${__CACHE_FIELDS[3]}" skipped="${__CACHE_FIELDS[4]}"

  [[ -n "$s" && -n "$t" ]] || return

  # Both of these reach `(( ))` below, and a cache entry written by an
  # OLDER version of this file will not have the shape this one expects.
  # That is not hypothetical: /tmp still holds entries from before
  # run_epoch became an integer, and feeding one of those to the
  # arithmetic prints
  #
  #   value too great for base (error token is "08")
  #
  # into the middle of the prompt, once per Enter, forever. The CI check
  # that configs emit nothing when sourced cannot see this — it happens at
  # prompt time, not source time — so the guard has to live here. Anything
  # non-numeric is treated as absent, which costs one refresh.
  case "$run_epoch" in
    *[!0-9]*) run_epoch="" ;;
  esac
  case "$skipped" in
    '' | *[!0-9]*) skipped=0 ;;
  esac

  local emoji
  case "$sym" in
    fail) emoji="❌" ;;
    run)  emoji="⏳" ;;
    *)    emoji="✅" ;;
  esac

  local skipped_str=""
  (( skipped > 0 )) && skipped_str=" (${skipped} skipped)"

  local age=""
  [[ -n "$run_epoch" ]] && __relative_age age "$run_epoch" "$now"

  __gh_out="${__C_GH}[${s}/${t} ${emoji}${skipped_str} ${age}]${__C_OFF}"
  # Visible: [ s / t <space> emoji <skipped> <space> age ] — the two
  # brackets, the slash and the two spaces are 5, and the emoji is East
  # Asian Wide, so 2 columns for its 1 character.
  __gh_w=$(( ${#s} + ${#t} + ${#skipped_str} + ${#age} + 7 ))
}

# ─── Repo visibility and branch protection ──────────────────────────
#
# Wrapped around the branch on the left side of the prompt:
#
#   🌍 main 🛡️     public repo, branch has protection rules
#   🔒 main        private repo, no rules on this branch
#
# Both answers live on GitHub, so both are fetched exactly the way CI
# status above is: a detached job writes a cache file, and the prompt
# reads it back with the `read` builtin. Nothing here forks on the prompt
# path. A repo you have not visited in the last __GH_REPO_TTL seconds
# therefore shows its branch bare for one prompt and decorated from the
# next one, which is the same one-prompt lag the CI segment has.
#
# Cache file: visibility|protected|fetch_epoch
#
# Keyed on worktree + branch, NOT on the commit sha the CI cache uses.
# Neither answer is a property of a commit — protection attaches to a
# branch NAME and visibility to the repo — so keying on the sha would
# throw away a still-correct answer on every commit and re-ask GitHub for
# it. The worktree is in the key because two worktrees of one repo can
# sit on different branches, and a submodule's visibility is its own.
__GH_REPO_CACHE_DIR="/tmp/gh_repo_cache"
__GH_REPO_TTL=300      # visibility and protection rules both change rarely

# Named so swapping one is a one-line edit. 🌍 and 🔒 are East Asian Wide
# by default; 🛡 is Neutral and needs the U+FE0F variation selector to
# render as an emoji at all, so terminals draw it 2 columns wide while
# wcwidth() calls it 1. That mismatch is harmless HERE and only here: it
# sits on the first line of a two-line PS1, and readline measures only the
# text after the last newline when it places the cursor. Moving any of
# these below the \n would make the width lie matter — see the __NP_ON
# comment above for what that class of bug looks like.
__EMOJI_PUBLIC="🌍"
__EMOJI_PRIVATE="🔒"
__EMOJI_PROTECTED="🛡️"

# __repo_meta_refresh <cache_file> <branch>
# A producer for __cache_get.
__repo_meta_refresh() {
  local cache_file="$1" branch="$2"
  local meta repo="" vis="" prot=0 rules protected

  # One call for both the slug and the visibility. `gh repo view` is also
  # what decides WHICH GitHub repo this directory is: it resolves the
  # remote itself, so forks, ssh/https spellings and multiple remotes all
  # land on the same answer git would give.
  meta=$(gh repo view --json nameWithOwner,visibility \
           -q '.nameWithOwner + "|" + .visibility' 2>/dev/null)
  IFS='|' read -r repo vis <<< "$meta"

  if [[ -n "$repo" && -n "$branch" ]]; then
    # Rulesets first. This endpoint needs no admin rights, and it answers
    # for branches that have never been pushed, because a ruleset matches
    # a NAME rather than an existing ref.
    rules=$(gh api "repos/${repo}/rules/branches/${branch}" -q 'length' 2>/dev/null)
    case "$rules" in
      '' | *[!0-9]*) rules=0 ;;
    esac
    if (( rules > 0 )); then
      prot=1
    else
      # Classic branch protection, which predates rulesets and which the
      # endpoint above does not report. `.protected` covers both schemes
      # — this repo's main has no classic protection and still reads true
      # off its rulesets — so it is the fallback and not the primary only
      # because it 404s on a branch that exists solely on this machine.
      protected=$(gh api "repos/${repo}/branches/${branch}" -q '.protected' 2>/dev/null)
      [[ "$protected" == "true" ]] && prot=1
    fi
  fi

  # No visibility means no GitHub repo here — a non-GitHub remote, a
  # deleted repo, an expired token. Drop the entry rather than caching a
  # blank, so the next prompt retries instead of showing nothing forever.
  if [[ -n "$vis" ]]; then
    printf '%s|%s|%s' "$vis" "$prot" "$(date +%s)" > "$cache_file"
  else
    rm -f "$cache_file"
  fi
}

# __repo_meta_segment <branch> <now_epoch>
# Sets __repo_pre (rendered left of the branch) and __repo_post (right of
# it). An empty branch still gets visibility — that is the detached-HEAD
# call, where there is no branch name for a rule to attach to.
# Spends no processes; only the background refresh it may launch does.
__repo_meta_segment() {
  __repo_pre=""
  __repo_post=""

  [[ "$GH_PROMPT" == "1" ]] || return
  local branch="$1" now="$2"
  command -v gh &>/dev/null || return

  # Slashes become % so that a path and a branch like feature/foo compose
  # into one filename. A worktree buried deeper than the 255-byte filename
  # limit simply fails to cache and shows a bare branch, which is the
  # right way for this to degrade.
  local key="${__GIT_TOPLEVEL:-$PWD}"
  key="${key//\//%}#${branch//\//%}"

  __cache_get "$__GH_REPO_CACHE_DIR" "$__GH_REPO_TTL" "$key" "$now" \
    __repo_meta_refresh "$branch"

  local vis="${__CACHE_FIELDS[0]}" prot="${__CACHE_FIELDS[1]}"

  # INTERNAL is an org repo visible to that org and nobody else. It is not
  # public, so it reads as the lock rather than inventing a third glyph.
  case "$vis" in
    PUBLIC)            __repo_pre="${__EMOJI_PUBLIC} " ;;
    PRIVATE|INTERNAL)  __repo_pre="${__EMOJI_PRIVATE} " ;;
  esac
  [[ "$prot" == "1" ]] && __repo_post=" ${__EMOJI_PROTECTED}"
  return 0
}

# ─── Will the pull fight you? ───────────────────────────────────────
#
# 🔼2  🔽3 says the pull is not a fast-forward. It does not say whether
# merging those commits will conflict, which is the part that decides
# whether you deal with it now or after lunch. `git merge-tree` answers
# exactly that: it performs the merge in memory and reports the result,
# touching no working tree, no index and no branch.
#
#   exit 0                  merges clean
#   exit 1 + stdout         conflicts; stdout is the tree oid then paths
#   exit 1 + NO stdout      the ref does not exist
#   exit 128 / 129          unrelated histories, or a git too old for
#                           --write-tree (added in 2.38)
#
# That third line is the trap. A missing upstream ref exits 1 exactly
# like a real conflict does, so the obvious `if ! git merge-tree ...`
# reports a conflict that does not exist every time the ref is gone. The
# tree oid on stdout is what tells them apart, and it is why this reads
# the output rather than trusting the status alone. Exit 129 is also why
# no version check is needed: an old git simply lands in the "unknown"
# case and the prompt stays quiet.
#
# ONLY RUN WHEN DIVERGED. Behind-but-not-ahead fast-forwards, and a
# fast-forward cannot conflict, so the common case never starts this at
# all. That matters: merge-tree is fast on a normal divergence (~1ms) but
# was measured at 11.66ms merging 40 commits against 40 over 400 shared
# files, and a prompt does not get to have a worst case like that. Hence
# the same background-cache shape as the two segments above.
#
# Cache file: conflicted_files|fetch_epoch
__GIT_MERGE_CACHE_DIR="/tmp/git_merge_cache"
__GIT_MERGE_TTL=300

# __merge_refresh <cache_file> <upstream>
# A producer for __cache_get.
__merge_refresh() {
  local cache_file="$1" upstream="$2"
  local out rc files=0 line first=1

  out=$(git --no-optional-locks merge-tree --write-tree --name-only \
          HEAD "$upstream" 2>/dev/null)
  rc=$?

  if (( rc == 1 )) && [[ -n "$out" ]]; then
    # Line 1 is the merged tree's oid. The conflicted paths follow it, and
    # a blank line ends them before git's human-readable explanation.
    while IFS= read -r line; do
      if (( first )); then first=0; continue; fi
      [[ -z "$line" ]] && break
      (( ++files ))
    done <<< "$out"
  elif (( rc != 0 )); then
    # Unknown, not clean. Drop the entry rather than cache a reassuring
    # zero — silence here already means "merges fine", and this is the one
    # indicator where guessing wrong in that direction is the bad way.
    rm -f "$cache_file"
    return
  fi

  printf '%s|%s' "$files" "$(date +%s)" > "$cache_file"
}

# __merge_segment <upstream> <oid> <ahead> <behind> <now_epoch>
# Sets __merge_out and __merge_w. Spends no processes; only the background
# refresh it may launch does.
__merge_segment() {
  __merge_out=""
  __merge_w=0

  local upstream="$1" oid="$2" ahead="$3" behind="$4" now="$5"
  [[ -n "$upstream" && -n "$oid" ]] || return

  # Keyed on both sides of the merge. The oid moves when you commit; the
  # behind count moves when a fetch brings something new, which is the
  # only way the upstream can change under you. An upstream force-pushed
  # to a DIFFERENT set of commits of the same length keeps the same key
  # and so keeps a stale answer until the TTL expires — the one case this
  # key cannot see, and the reason there is a TTL at all rather than
  # caching forever on an exact key.
  local key="${__GIT_TOPLEVEL:-$PWD}"
  key="${key//\//%}#${oid}#${ahead}#${behind}"

  __cache_get "$__GIT_MERGE_CACHE_DIR" "$__GIT_MERGE_TTL" "$key" "$now" \
    __merge_refresh "$upstream"

  local files="${__CACHE_FIELDS[0]}"

  case "$files" in
    '' | *[!0-9]* | 0) return ;;
  esac

  __merge_out="${__C_CONFLICT}${files} conflicting${__C_OFF}  "
  (( __merge_w = ${#files} + 14 ))               # " conflicting" + 2 spaces
  return 0
}

# ─── Is there a repo here at all? ───────────────────────────────────
#
# Forking git only to have it walk up the tree and fail costs ~700us on
# the Linux filesystem and ~1.6ms under /mnt, where every stat crosses
# drvfs. Walking the same parents in bash costs 7us in a repo and 287us
# in the worst /mnt case, so this is worth doing before the fork.
#
# It deliberately answers a slightly different question from git's, and
# is therefore only ever used to SKIP work, never to claim a repo exists.
# The two ways it disagrees, both measured against real repos:
#
#   inside a .git directory  it says yes where git says no. Harmless —
#                            git is forked, fails, and its answer wins.
#   GIT_DIR / GIT_WORK_TREE  it would say no where git says yes, which
#                            would silently drop the branch. Shells
#                            spawned from git hooks have these set, so
#                            they bypass the fast path entirely.
#
# Sets __GIT_TOPLEVEL as a side effect, which saves asking git for it.
__in_git_tree() {
  __GIT_TOPLEVEL=""
  # Let git answer whenever the environment overrides where the repo is.
  [[ -n "$GIT_DIR" || -n "$GIT_WORK_TREE" ]] && return 0
  local d="$PWD"
  while :; do
    # -e, not -d: in a linked worktree or a submodule, .git is a file.
    [[ -e "$d/.git" ]] && { __GIT_TOPLEVEL="$d"; return 0; }
    [[ -z "$d" || "$d" == / ]] && return 1
    d="${d%/*}"
    [[ -z "$d" ]] && d=/
  done
}

# __repo_has_remote <toplevel>
# True if .git/config declares any remote at all. Read with the `read`
# builtin (22us) rather than `git remote` (716us, a fork).
#
# Only reached when the branch has no upstream, so the common case pays
# nothing. Anything it cannot read counts as "has a remote", because the
# warning this drives should never fire on a guess.
__repo_has_remote() {
  local cfg="$1/.git/config" line
  # .git is a file in a worktree or submodule, so config lives elsewhere;
  # no toplevel at all means GIT_DIR is in play. Both stay quiet.
  [[ -n "$1" && -f "$cfg" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == '[remote '* ]] && return 0
  done < "$cfg"
  return 1
}

# ─── The prompt ─────────────────────────────────────────────────────
#
# Sets __PS1_CONDA and __PS1_GIT for PS1 to read, then prints the right
# side at the right edge using ANSI cursor positioning (\033[{col}G)
# followed by a carriage return, so PS1 redraws over it from column 0.

__prompt_render() {
  local st line xy ab
  local head="" oid="" staged=0 modified=0 untracked=0 ahead=0 behind=0
  # The upstream's NAME, not a flag. porcelain v2 hands it over for free
  # and the merge check below needs something to merge against; emptiness
  # still answers the "is there an upstream at all" question a flag did.
  local upstream=""

  __PS1_CONDA=""
  if [[ -n "$CONDA_DEFAULT_ENV" ]]; then
    __PS1_CONDA="${__NP_ON}${__C_CONDA}${__NP_OFF}(${CONDA_DEFAULT_ENV})${__NP_ON}${__C_OFF}${__NP_OFF} "
  fi

  # Cleared before the git call, not after it: leaving a repo has to drop
  # the branch, and the early return below is the path that does it.
  __PS1_GIT=""

  # Skip the fork entirely in directories with no repo above them — see
  # __in_git_tree for why it is safe to trust a "no" here.
  __in_git_tree || return

  # The one process this prompt spends. --no-optional-locks keeps it from
  # taking the index lock, so pressing Enter cannot contend with a rebase
  # running in another terminal.
  st=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null) || return

  while IFS= read -r line; do
    case "$line" in
      '# branch.oid '*)  oid="${line#'# branch.oid '}" ;;
      '# branch.head '*) head="${line#'# branch.head '}" ;;
      '# branch.upstream '*) upstream="${line#'# branch.upstream '}" ;;
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
      '? '*)             (( ++untracked )) ;;
    esac
  done <<< "$st"

  # An unborn branch reports "(initial)" — a placeholder, not a sha, and
  # nothing to ask GitHub about.
  [[ "$oid" == '(initial)' ]] && oid=""
  # porcelain v2 says "(detached)" where the old prompt showed
  # `git rev-parse --short`, which picks its length by ambiguity. Seven is
  # what it returns for repos this size.
  #
  # prot_branch stays empty while detached, because what is displayed then
  # is a sha, and protection rules attach to branch names. Asking GitHub
  # whether a sha is protected is not a question it has an answer to.
  local prot_branch=""
  if [[ "$head" == '(detached)' ]]; then
    head="${oid:0:7}"
  else
    prot_branch="$head"
  fi

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
  # Counts porcelain ENTRIES, not files. Git's default -unormal collapses
  # an untracked directory into one `?` line, so a new build/ holding 500
  # files reads as 1. That is the more useful number — it counts things
  # you would have to act on, and one .gitignore line covers that
  # directory — but it is not a file count, and nothing here should imply
  # it is. Making it a true file count means -uall, which is the untracked
  # mode that actually costs time on a large tree, spent to buy a number
  # whose only distinct behaviour is being alarming.
  if (( untracked )); then
    right+="${__C_UNTRACKED}${untracked} untracked${__C_OFF}  "
    (( w += ${#untracked} + 12 ))                  # " untracked" + 2 spaces
  fi
  # Two independent ifs, not an if/elif/elif with a third glyph for the
  # both-at-once case. Seeing 🔼 and 🔽 together IS the diverged signal,
  # so it needs no symbol of its own, and the counts can no longer be read
  # in the wrong order the way a single 🔄2/3 could be.
  if (( ahead )); then
    right+="🔼${ahead}  "
    (( w += ${#ahead} + 4 ))
  fi
  if (( behind )); then
    right+="🔽${behind}  "
    (( w += ${#behind} + 4 ))
  fi

  # The bracketed slot reports this repo's relationship with its remote.
  # Usually that is CI status; when there is nothing to have a
  # relationship WITH, it says so instead, and there is no point asking
  # GitHub about a repo GitHub has never heard of.
  #
  # Keyed on "no remote configured", NOT on "no upstream". A branch you
  # have created and not yet pushed has no upstream and is completely
  # normal — warning about that would nag on every new branch. No remote
  # at all is the condition worth surfacing: nothing here is backed up.
  #
  # The globe/lock and shield are gated on the same condition, and not
  # only to save the calls: a repo with no remote has no GitHub
  # visibility to report and no rules that could apply to it, so the
  # honest rendering of both is nothing at all.
  __repo_pre=""
  __repo_post=""
  if [[ -z "$upstream" ]] && ! __repo_has_remote "$__GIT_TOPLEVEL"; then
    right+="${__C_WARN}[no origin]${__C_OFF}"
    (( w += 11 ))
  else
    local now
    # $EPOCHSECONDS is a bash 5 builtin; macOS /bin/bash is 3.2. Read once
    # and handed to both segments — on 3.2 it is a fork, and two of them
    # for the same number would be one too many.
    if (( BASH_VERSINFO[0] >= 5 )); then now="$EPOCHSECONDS"; else now=$(date +%s); fi

    __repo_meta_segment "$prot_branch" "$now"

    # Only when diverged. Behind-alone fast-forwards and cannot conflict,
    # so this never starts outside the state the two arrows already show.
    if (( ahead && behind )); then
      __merge_segment "$upstream" "$oid" "$ahead" "$behind" "$now"
      right+="$__merge_out"
      (( w += __merge_w ))
    fi

    __gh_segment "$oid" "$now"
    right+="$__gh_out"
    (( w += __gh_w ))
  fi

  # Assembled here rather than where the branch was parsed, because the
  # decorations are not known until the segment above has run. The emoji
  # are deliberately OUTSIDE the \001..\002 colour markers: they are
  # visible characters and readline has to count them, where the colour
  # bytes are invisible and it must not.
  __PS1_GIT=" ${__repo_pre}${__NP_ON}${__C_BRANCH}${__NP_OFF}${head}${__NP_ON}${__C_OFF}${__NP_OFF}${__repo_post}"

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
