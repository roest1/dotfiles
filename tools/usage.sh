#!/usr/bin/env bash
set -euo pipefail

# ─── Audit aid: how often is each shell command actually used? ──────────────
#
#   ./tools/usage.sh            every function and alias, zeros first
#   ./tools/usage.sh --since 2026-06-01
#
# The June 2026 pruning was done on judgement, and the only evidence
# available afterwards was 8,900 lines of one machine's history with no
# dates on them. This is the evidence that cleanup should have had, read
# from the two records the configs now keep:
#
#   ~/.bash_history             bashrc appends it after every prompt
#                               (`history -a`) and stamps each line
#                               (HISTTIMEFORMAT), so a closed window loses
#                               nothing and "last used" is answerable.
#   ~/.local/state/nvim/        keymap-usage.json, written by
#                               nvim/lua/external/usage.lua. :KeymapUsage
#                               shows it inside the editor; it is listed here
#                               only so one command gives the whole picture.
#
# Both live in $HOME, outside the work tree, by the same argument that keeps
# ~/.bash_local there: git cannot commit what it cannot see. This script reads
# them and writes nothing.
#
# Deliberately NOT a make target, for the reason adopt.sh is not: the
# Makefile operates the repo, this edits it. The set of commands it counts
# is the set CI already checks `h` against -- a function or alias defined in
# bash/bash_productivity, bash/bash_git or bash/bash_github -- so the two
# cannot disagree about what a "command" is.
#
# Limits, stated rather than hidden: this reads ONE machine's history.
# A zero here means "not on this machine since its history began", not
# "never". Lines written before HISTTIMEFORMAT was set have no stamp and
# report `-` for last use; they still count.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HIST="${HISTFILE:-$HOME/.bash_history}"
NVIM_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/nvim/keymap-usage.json"

since=""
if [[ "${1:-}" == "--since" ]]; then
  since="${2:?--since needs a YYYY-MM-DD date}"
  since_epoch="$(date -d "$since" +%s)"
fi

# Same extraction the CI `h` check uses, so "command" means the same thing.
mapfile -t commands < <(
  {
    grep -hoE '^[a-zA-Z0-9_][a-zA-Z0-9_-]*\(\)' \
      "$ROOT/bash/bash_productivity" "$ROOT/bash/bash_git" "$ROOT/bash/bash_github" | tr -d '()'
    grep -hE '^[[:space:]]*alias ' \
      "$ROOT/bash/bash_productivity" "$ROOT/bash/bash_git" "$ROOT/bash/bash_github" \
      | sed 's/.*alias //;s/=.*//'
  } | grep -vE '^_' | sort -u
)

if [[ ! -r "$HIST" ]]; then
  echo "no history at $HIST" >&2
  exit 1
fi

# One pass over history: a `#<epoch>` line stamps the command that follows
# it. Count by first word (after an optional sudo), remember the latest
# stamp per word.
declare -A count last
stamp=""
while IFS= read -r line; do
  if [[ "$line" =~ ^#([0-9]{9,})$ ]]; then
    stamp="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ -n "$since" && -n "$stamp" && "$stamp" -lt "$since_epoch" ]]; then
    stamp=""
    continue
  fi
  word="${line#sudo }"
  word="${word%% *}"
  [[ -n "$word" ]] || continue
  count["$word"]=$(( ${count["$word"]:-0} + 1 ))
  if [[ -n "$stamp" && "$stamp" -gt "${last["$word"]:-0}" ]]; then
    last["$word"]="$stamp"
  fi
  stamp=""
done < "$HIST"

echo "shell commands  (${HIST}${since:+, since $since})"
echo "----------------------------------------------------------"
printf '%6s  %-20s %s\n' count command 'last used'
for c in "${commands[@]}"; do
  n="${count["$c"]:-0}"
  if [[ -n "${last["$c"]:-}" ]]; then
    when="$(date -d "@${last["$c"]}" +%F)"
  else
    when="-"
  fi
  printf '%6d  %-20s %s\n' "$n" "$c" "$when"
done | sort -n -k1,1 -k2,2

echo ""
if [[ -r "$NVIM_STATE" ]] && command -v jq >/dev/null 2>&1; then
  echo "nvim mappings  ($NVIM_STATE)"
  echo "----------------------------------------------------------"
  printf '%6s  %-24s %s\n' count mapping 'last used'
  # Keys are "<mode> <lhs>"; the file only holds mappings that were pressed
  # at least once. :KeymapUsage inside nvim is the view that includes zeros,
  # because only a running editor knows the full mapping set.
  jq -r 'to_entries[] | "\(.value.count)\t\(.key)\t\(.value.last // "-")"' "$NVIM_STATE" \
    | sort -n -k1,1 \
    | awk -F'\t' '{ printf "%6d  %-24s %s\n", $1, $2, $3 }'
  echo "  (pressed-at-least-once only; :KeymapUsage in nvim lists the zeros)"
else
  echo "nvim mappings: no $NVIM_STATE yet — open nvim, press things, :KeymapUsage"
fi
