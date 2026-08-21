#!/usr/bin/env bash
# ─── deps.conf parser ────────────────────────────────────────────────────────
#
# The manifest is the single source of truth for what this repo links and
# installs. Everything else (install.sh, the Makefile, check) reads it through
# here, so adding a program is a section in deps.conf and nothing else.
#
# Deliberately a plain `read` loop, not a config library: the file has to stay
# greppable, diff-friendly, and parseable on a machine where the only thing you
# can count on is bash.
#
# Usage:
#   source lib/manifest.sh
#   manifest_sections                       # section names, in file order
#   manifest_lines <kind> [section...]      # kind = link|tool|post
#
# manifest_lines emits one record per line, fields tab-separated. With no
# section filter it emits every section's lines.
#
# Every section is visible wherever this file is read. There is no per-section
# platform filter, and no `platform` line type: the only section that ever
# needed one was the Windows host's wezterm, and windows/install.ps1 declares
# its own payload rather than parsing this manifest.

MANIFEST_FILE="${MANIFEST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deps.conf}"

# List section names in the order they appear.
manifest_sections() {
  local raw line

  [[ -f "$MANIFEST_FILE" ]] || { echo "manifest not found: $MANIFEST_FILE" >&2; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    [[ "$line" =~ ^\[([A-Za-z0-9_-]+)\] ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done < "$MANIFEST_FILE"
}

# ─── This machine's sections ─────────────────────────────────────────────────
#
# deps.conf is the CATALOGUE: everything this repo knows how to install, the
# same on every machine, in git. This file is the per-machine SUBSET — the
# laptop with no wezterm, the server with no nvim, the box that does not want
# a Rust toolchain — and it is deliberately not in the work tree.
#
# That placement is the whole point, and it is the argument ~/.bash_local
# already settles. "Toggling is commenting" is true of deps.conf and it is why
# this file has to exist: commenting a line there is a TRACKED EDIT, so a
# machine-local preference becomes a diff you carry forever or commit by
# accident. Outside the tree git cannot see it — it cannot be committed, cannot
# leak one machine's choices into another's checkout, and cannot be deleted by
# someone rewriting .gitignore. Inside the tree it would be protected only by a
# rule that `git add -f` overrides.
#
# Absent — the normal case, and every fresh machine — means EVERY section. The
# catalogue stays the default; this file only ever narrows it.
#
# Seed it with the command that prints exactly this list:
#   mkdir -p ~/.config/dotfiles && make sections > ~/.config/dotfiles/sections
# then comment out what this machine does not want. Commenting, the same idiom
# as deps.conf, because there is no second one worth learning.
DOTFILES_SECTIONS_FILE="${DOTFILES_SECTIONS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/sections}"

manifest_enabled() {
  local raw line

  if [[ ! -f "$DOTFILES_SECTIONS_FILE" ]]; then
    manifest_sections
    return 0
  fi

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # A name that is not in the manifest is a typo, and a typo that silently
    # installs nothing is the failure this file exists to prevent. Said on
    # stderr so it cannot land in `make sections`'s output or in a pipe CI
    # greps; the names that ARE real still run.
    if manifest_has_section "$line"; then
      printf '%s\n' "$line"
    else
      echo "warning: $DOTFILES_SECTIONS_FILE names '$line', which is not a section in deps.conf" >&2
    fi
  done < "$DOTFILES_SECTIONS_FILE"
}

# The sections a command should act on: the ones asked for, or this machine's
# set when none were.
#
# Naming a section explicitly always wins. Opting out of [claude] is a
# statement about the default sweep, not a lock — `make install claude` still
# installs it, which is what makes the file a preference rather than a wall.
manifest_scope() {
  if (( $# )); then
    printf '%s\n' "$@"
  else
    manifest_enabled
  fi
}

# Fill an array with the scope, and say whether there is anything in it.
#
# The empty case is the trap this exists for. `manifest_lines tool` with no
# section arguments means EVERY section — that is what makes a bare
# `make install` work — so a sections file with everything commented out would
# expand to no arguments and quietly install the lot. Exactly backwards.
# Callers check the return rather than the array length, so the mistake is
# impossible to make twice.
#
#   local -a scope
#   manifest_scope_into scope "$@" || return 0
manifest_scope_into() {
  local -n _dest="$1"; shift
  mapfile -t _dest < <(manifest_scope "$@")
  (( ${#_dest[@]} )) && return 0
  echo "no sections enabled in $DOTFILES_SECTIONS_FILE — comment a line back in," >&2
  echo "or delete the file to get every section" >&2
  return 1
}

# NOT `manifest_sections | grep -qxF "$1"`. Callers run under `set -o pipefail`
# (install.sh, and the Makefile recipes), where that spelling is a race: `grep
# -q` exits the moment it matches, manifest_sections takes SIGPIPE still
# writing, and pipefail reports 141 for the pipeline — so a section that IS
# present reads as absent. It depends on whether the producer finishes before
# the consumer leaves, which is why it passed on one CI runner and failed on
# two. Process substitution has no pipeline status to poison.
manifest_has_section() {
  local name
  while IFS= read -r name; do
    [[ "$name" == "$1" ]] && return 0
  done < <(manifest_sections)
  return 1
}

# manifest_lines <kind> [section...]
#
# Emits tab-separated records for the requested kind:
#   link  ->  <section>\t<repo-path>\t<dest>
#   tool  ->  <section>\t<provider>\t<command>\t<package>
#   post  ->  <section>\t<command line>
#
# Commented lines are skipped — that IS the toggle mechanism, so it must be
# the first thing this loop does and must never be worked around.
manifest_lines() {
  local want_kind="$1"; shift
  local -a want_sections=("$@")
  local section="" kind a b c rest

  [[ -f "$MANIFEST_FILE" ]] || { echo "manifest not found: $MANIFEST_FILE" >&2; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # strip trailing inline comments, then surrounding whitespace
    local line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # section header
    if [[ "$line" =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # filter by requested sections
    if [[ ${#want_sections[@]} -gt 0 ]]; then
      local match=0 s
      for s in "${want_sections[@]}"; do [[ "$s" == "$section" ]] && match=1; done
      [[ $match -eq 1 ]] || continue
    fi

    read -r kind a b c rest <<<"$line"
    [[ "$kind" == "$want_kind" ]] || continue

    case "$kind" in
      link)
        # expand ~ in the destination
        printf '%s\t%s\t%s\n' "$section" "$a" "${b/#\~/$HOME}"
        ;;
      tool)
        # provider command [package]; package defaults to command
        printf '%s\t%s\t%s\t%s\n' "$section" "$a" "$b" "${c:-$b}"
        ;;
      post)
        # everything after `post` is the command line
        printf '%s\t%s\n' "$section" "$(echo "$a $b $c $rest" | sed 's/[[:space:]]*$//')"
        ;;
    esac
  done < "$MANIFEST_FILE"
}

# Validate that requested sections exist; print a useful error if not.
#
# `windows` gets its own message rather than a bare "Unknown section". It was a
# section here until the Windows installer stopped reading this file, and
# pointing at the entry point that does install it is more useful than a list
# that conspicuously lacks the name you just typed.
manifest_validate_sections() {
  local s rc=0
  for s in "$@"; do
    if manifest_has_section "$s"; then
      continue
    fi

    if [[ "$s" == "windows" ]]; then
      echo "There is no [windows] section: the Windows host is installed by" >&2
      echo "  windows/install.ps1, run from PowerShell on the host itself —" >&2
      echo "  not by this script inside WSL. It declares its own payload." >&2
    else
      echo "Unknown section: $s" >&2
      echo "Available: $(manifest_sections | tr '\n' ' ')" >&2
    fi
    rc=1
  done
  return $rc
}
