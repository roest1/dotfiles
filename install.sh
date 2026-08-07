#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# ~/dotfiles/install.sh
#
# Symlinks config into place, driven entirely by the `link` lines in
# deps.conf. Safe to re-run — skips correct links, backs up anything
# it would overwrite to ~/.dotfiles_backup/<timestamp>/.
#
# Symlinks ONLY. No packages, no sudo, no network — which makes this
# the right entry point on a locked-down machine where you can't
# install anything but still want your config.
#
# Usage:
#   ./install.sh              # every section in deps.conf
#   ./install.sh bash         # one section
#   ./install.sh bash nvim    # several
#
# Tool installation is `make install` — see `make help`.
#####################################################################

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

# shellcheck source=lib/manifest.sh
source "$DOTFILES_DIR/lib/manifest.sh"

case "$(uname -s)" in
  Darwin) _OS=mac ;;
  *)      _OS=linux ;;
esac

SECTIONS=("$@")
if [[ ${#SECTIONS[@]} -gt 0 ]]; then
  manifest_validate_sections "${SECTIONS[@]}"
fi

# --- Helpers -------------------------------------------------------

link_file() {
  local src="$1"
  local dest="$2"

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    echo "  ok $dest"
    return
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    mkdir -p "$BACKUP_DIR"
    mv "$dest" "$BACKUP_DIR/"
    echo "  backed up $dest -> $BACKUP_DIR/"
  fi

  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  echo "  linked $dest -> $src"
}

# Remove symlinks this repo left behind that it no longer declares.
#
# Renaming a config file breaks the old link in a way nothing else notices:
# ~/.bash_roest_theme still exists, still looks like a working dotfile, and
# points at a repo path that is gone. It isn't in the manifest any more, so the
# link loop never walks it — leaving the old and new names side by side in
# $HOME, which is exactly the mess a rename is supposed to avoid.
#
# Deliberately NOT a list of retired names. The test is structural: a symlink
# that points INTO this repo and whose target no longer exists is an orphan of
# this repo, whatever it was once called. That stays correct for the next
# rename without anyone remembering to update it — and it cannot touch a link
# that still resolves, or one pointing anywhere else.
#
# Scope comes from the manifest too: only directories this repo actually links
# into are scanned, one level deep, so it can never wander through $HOME.
prune_orphans() {
  local dirs=$'\n'
  local section src dest dir link target header=0

  while IFS=$'\t' read -r section src dest; do
    dir="$(dirname "$dest")"
    [[ "$dirs" == *$'\n'"$dir"$'\n'* ]] || dirs+="$dir"$'\n'
  done < <(manifest_lines link ${SECTIONS[@]+"${SECTIONS[@]}"})

  while IFS= read -r dir; do
    [[ -z "$dir" || ! -d "$dir" ]] && continue
    # Both globs, because the interesting ones are dotfiles. A pattern that
    # matches nothing stays literal and fails the -L test, so no nullglob.
    for link in "$dir"/* "$dir"/.*; do
      [[ -L "$link" ]] || continue
      target="$(readlink "$link")"
      [[ "$target" == "$DOTFILES_DIR"/* ]] || continue
      [[ -e "$target" ]] && continue
      if [[ $header -eq 0 ]]; then
        echo ""
        echo "[orphaned links]"
        header=1
      fi
      rm -f "$link"
      echo "  pruned $link (target gone: $target)"
    done
  done <<< "$dirs"

  return 0
}

echo ""
echo "Linking dotfiles from $DOTFILES_DIR ($_OS)"
if [[ ${#SECTIONS[@]} -gt 0 ]]; then
  echo "Sections: ${SECTIONS[*]}"
else
  echo "Sections: $(manifest_sections | tr '\n' ' ')"
fi
echo "-------------------------------------------"

# --- Walk the manifest's link lines --------------------------------

current=""
linked_any=0
while IFS=$'\t' read -r section src dest; do
  [[ -z "$section" ]] && continue
  if [[ "$section" != "$current" ]]; then
    current="$section"
    echo ""
    echo "[$section]"
  fi
  link_file "$DOTFILES_DIR/$src" "$dest"
  linked_any=1
done < <(manifest_lines link ${SECTIONS[@]+"${SECTIONS[@]}"})

[[ $linked_any -eq 0 ]] && echo "  (nothing to link)"

# After linking, not before: an orphan is defined by the manifest's current
# contents, and this way a link that was just re-pointed is already correct
# rather than looking briefly stale.
prune_orphans

# --- Git hooks -----------------------------------------------------
#
# .githooks/ is tracked, so the pre-commit secret guard arrives with a clone
# instead of being something every machine has to remember to set up. Git
# ignores tracked hooks unless core.hooksPath points at them.
#
# Repo-local config, never --global: this hook is about THIS repo's rules, and
# a global hooksPath would silently replace the hooks of every other repo on
# the machine.
# Every git call here is allowed to fail without taking install.sh with it. A
# `.git` directory is not sufficient for git to accept the repo: under a CI
# container, or anywhere the work tree is owned by another user, git rejects it
# for dubious ownership and `config --local` exits 128. Linking your dotfiles
# must not fail because a hook could not be registered.
if [[ -d "$DOTFILES_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
  current="$(git -C "$DOTFILES_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [[ "$current" != ".githooks" ]]; then
    echo ""
    echo "[git hooks]"
    if git -C "$DOTFILES_DIR" config --local core.hooksPath .githooks 2>/dev/null; then
      echo "  set core.hooksPath -> .githooks"
    else
      echo "  skipped — git declined this work tree (ownership?)"
      echo "  The secret guard is not active here. CI still checks it."
    fi
  fi
fi

# --- Login shell shim (.bash_profile) ------------------------------
#
# Login shells (macOS Terminal/iTerm2, SSH on Linux/RHEL) read
# ~/.bash_profile instead of ~/.bashrc. This shim ensures .bashrc is
# always loaded regardless of shell mode. Generated rather than tracked
# because it's boilerplate, and only relevant when bash is being linked.

if [[ ${#SECTIONS[@]} -eq 0 ]] || printf '%s\n' "${SECTIONS[@]}" | grep -qx bash; then
  echo ""
  echo "[bash] login shell shim:"

  local_bash_profile="$DOTFILES_DIR/bash/bash_profile"
  if [[ ! -f "$local_bash_profile" ]]; then
    cat > "$local_bash_profile" <<'SHIM'
# ~/.bash_profile — login shell shim
# Source .bashrc so interactive login shells get the full config.
# Generated by dotfiles/install.sh
[[ -f ~/.bashrc ]] && source ~/.bashrc
SHIM
    echo "  created $local_bash_profile"
  fi
  link_file "$local_bash_profile" "$HOME/.bash_profile"
fi

# --- Summary -------------------------------------------------------

echo ""
echo "-------------------------------------------"

if [[ -d "$BACKUP_DIR" ]]; then
  echo "Backed up existing files to: $BACKUP_DIR"
fi

if [[ "$_OS" == "mac" ]]; then
  current_shell="$(dscl . -read /Users/"$USER" UserShell 2>/dev/null | awk '{print $2}')"
  if [[ "$current_shell" != *bash* ]]; then
    echo ""
    echo "NOTE: Your default shell is $current_shell"
    echo "  To switch to bash:  make shell   (or: chsh -s /bin/bash)"
  fi
fi

echo "Done! Restart your shell or run: reload"
echo ""
