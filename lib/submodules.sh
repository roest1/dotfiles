#!/usr/bin/env bash
# ─── Submodules that are not checked out yet ─────────────────────────────────
#
# Used by install.sh and by .githooks/post-merge, so a pull, a rebase and
# `make install` share one rule: check out a submodule that is not checked
# out, and never touch one that is. `submodule update` on a checkout you are
# working in would move its HEAD back to the pin.
#
# Why the hook is needed: submodule.recurse makes `git pull` move submodules
# that are already checked out, but one the pull ADDS arrives as an empty
# directory, and whatever links into it silently goes missing.
#
# To keep one out on a machine: git config submodule.<name>.update none.
# It is left out here rather than passed to git, which would print
# "Skipping submodule" on every pull.

# Paths of submodules in $1 that are not checked out and not opted out.
submodules_missing() {
  local root="$1" path name
  git -C "$root" submodule status 2>/dev/null | sed -n 's/^-[0-9a-f]* \([^ ]*\).*/\1/p' |
    while IFS= read -r path; do
      name=$(git -C "$root" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null |
        awk -v p="$path" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1 }')
      [[ "$(git -C "$root" config --get "submodule.${name:-$path}.update" 2>/dev/null)" == none ]] && continue
      printf '%s\n' "$path"
    done
}

# Check each of them out. Needs the network; a failure is reported, not fatal.
submodules_checkout_missing() {
  local root="$1" sub
  while IFS= read -r sub; do
    [[ -n "$sub" ]] || continue
    echo "  ➡️  checking out submodule $sub"
    git -C "$root" submodule update --init --quiet -- "$sub" \
      || echo "  ⚠️  submodule $sub: could not check out (offline?) — links into it are skipped"
  done < <(submodules_missing "$root")
}
