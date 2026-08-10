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
#   manifest_sections                       # section names for THIS platform
#   manifest_lines <kind> [section...]      # kind = link|tool|post
#
# manifest_lines emits one record per line, fields tab-separated. With no
# section filter it emits every section's lines.
#
# A section may declare `platform <name>`, in which case it is invisible to
# every function here unless <name> matches the platform bash is running on.
# windows/install.ps1 has its own parser and reads the windows sections; this
# one never does, because the two disagree about where `~` points and about
# what a symlink is.

MANIFEST_FILE="${MANIFEST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deps.conf}"

# Overridable so CI can parse another platform's sections without being on it.
# Not an escape hatch for installing: MANIFEST_PLATFORM=windows ./install.sh
# would link a Windows config into a Linux $HOME.
if [[ -z "${MANIFEST_PLATFORM:-}" ]]; then
  case "$(uname -s)" in
    Darwin) MANIFEST_PLATFORM=mac ;;
    *)      MANIFEST_PLATFORM=linux ;;
  esac
fi

# Emit "<section>\t<platform>" for every section in file order. Platform is
# empty for sections that declare none, which is almost all of them.
#
# Parallel indexed arrays rather than one associative array: macOS ships bash
# 3.2, where `declare -A` does not exist.
manifest_section_platforms() {
  local -a names=() plats=()
  local idx=-1 raw line kind rest

  [[ -f "$MANIFEST_FILE" ]] || { echo "manifest not found: $MANIFEST_FILE" >&2; return 1; }

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_-]+)\] ]]; then
      idx=$((idx + 1))
      names[$idx]="${BASH_REMATCH[1]}"
      plats[$idx]=""
      continue
    fi

    [[ $idx -ge 0 ]] || continue
    read -r kind rest <<<"$line"
    [[ "$kind" == "platform" ]] && plats[$idx]="$rest"
  done < "$MANIFEST_FILE"

  local i
  for ((i = 0; i <= idx; i++)); do
    printf '%s\t%s\n' "${names[$i]}" "${plats[$i]}"
  done
}

# List section names in the order they appear, minus sections belonging to
# another platform.
#
# That exclusion is load-bearing, not cosmetic: [wezterm] and [windows] both
# declare ~/.config/wezterm/wezterm.lua as their destination. Without the
# filter, a bare `./install.sh` inside WSL walks both and the second one
# silently overwrites the first.
manifest_sections() {
  local name plat
  while IFS=$'\t' read -r name plat; do
    [[ -z "$plat" || "$plat" == "$MANIFEST_PLATFORM" ]] || continue
    printf '%s\n' "$name"
  done < <(manifest_section_platforms)
}

manifest_has_section() {
  manifest_sections | grep -qxF "$1"
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

  # Newline-delimited allowlist, matched with a glob below. A `grep` per line
  # would fork once per manifest entry; this stays inside bash and works in 3.2.
  local allowed
  allowed=$'\n'"$(manifest_sections)"$'\n'

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

    # drop sections declared for another platform, however they were asked for
    [[ "$allowed" == *$'\n'"$section"$'\n'* ]] || continue

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
# A section that exists but belongs to another platform gets its own message.
# Reporting `make install windows` as "Unknown section" would be a lie, and the
# useful thing to say is which entry point does install it.
manifest_validate_sections() {
  local s rc=0 name plat found
  for s in "$@"; do
    found=""
    while IFS=$'\t' read -r name plat; do
      if [[ "$name" == "$s" ]]; then found="${plat:-any}"; break; fi
    done < <(manifest_section_platforms)

    if [[ -z "$found" ]]; then
      echo "Unknown section: $s" >&2
      echo "Available: $(manifest_sections | tr '\n' ' ')" >&2
      rc=1
    elif [[ "$found" != "any" && "$found" != "$MANIFEST_PLATFORM" ]]; then
      echo "Section [$s] declares 'platform $found'; this machine is $MANIFEST_PLATFORM." >&2
      echo "  Windows sections are installed by windows/install.ps1 run from" >&2
      echo "  PowerShell on the Windows host — not by this script inside WSL." >&2
      rc=1
    fi
  done
  return $rc
}
