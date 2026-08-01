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
#   manifest_sections                       # all section names, in file order
#   manifest_lines <kind> [section...]      # kind = link|tool|post
#
# manifest_lines emits one record per line, fields tab-separated. With no
# section filter it emits every section's lines.

MANIFEST_FILE="${MANIFEST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deps.conf}"

# List section names in the order they appear.
manifest_sections() {
  [[ -f "$MANIFEST_FILE" ]] || { echo "manifest not found: $MANIFEST_FILE" >&2; return 1; }
  sed -nE 's/^\[([A-Za-z0-9_-]+)\].*/\1/p' "$MANIFEST_FILE"
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
      ignore)
        # a command deliberately NOT managed here — project-scoped tools, one-offs.
        # Records the decision so `make status` stops reporting it as an orphan.
        printf '%s\t%s\n' "$section" "$a"
        ;;
    esac
  done < "$MANIFEST_FILE"
}

# Validate that requested sections exist; print a useful error if not.
manifest_validate_sections() {
  local s rc=0
  for s in "$@"; do
    if ! manifest_has_section "$s"; then
      echo "Unknown section: $s" >&2
      echo "Available: $(manifest_sections | tr '\n' ' ')" >&2
      rc=1
    fi
  done
  return $rc
}
