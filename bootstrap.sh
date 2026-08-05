#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# ~/dotfiles/bootstrap.sh — one-line entry point for a fresh machine
#
#   curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
#
# Solves the chicken-and-egg: you need the repo before you can run
# anything in it. Installs git if missing, clones over HTTPS (a fresh
# machine has no SSH key yet), then hands off to make.
#
# Pick a scope with DOTFILES_TARGET:
#   DOTFILES_TARGET=install ... | bash   # default — everything in deps.conf
#   DOTFILES_TARGET=bash    ... | bash   # one section (any [name] in deps.conf)
#   DOTFILES_TARGET=link    ... | bash   # symlinks only, no sudo/network
#
# Already cloned? Just use make directly — see `make help`.
#####################################################################

REPO_URL="${DOTFILES_REPO:-https://github.com/roest1/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
TARGET="${DOTFILES_TARGET:-install}"

# TARGET is validated AFTER cloning, not here: on the fresh machine this script
# exists for, deps.conf doesn't exist yet, so a section name couldn't be checked.

echo ""
echo "dotfiles bootstrap"
echo "-------------------------------------------"
echo "  repo:   $REPO_URL"
echo "  dest:   $DOTFILES_DIR"
echo "  target: make $TARGET"
echo ""

# --- git -----------------------------------------------------------

if ! command -v git >/dev/null 2>&1; then
  echo "git not found — installing..."
  if command -v brew >/dev/null 2>&1; then
    brew install git
  elif command -v apt >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y git
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git
  else
    echo "No supported package manager (brew/apt/dnf). Install git manually."
    exit 1
  fi
fi

# --- clone or update -----------------------------------------------

if [[ -d "$DOTFILES_DIR/.git" ]]; then
  echo "Already cloned — pulling latest..."
  git -C "$DOTFILES_DIR" pull --ff-only || echo "  (pull skipped — local changes or diverged branch)"
else
  if [[ -e "$DOTFILES_DIR" ]]; then
    echo "$DOTFILES_DIR exists but is not a git repo. Move it aside and re-run."
    exit 1
  fi
  git clone "$REPO_URL" "$DOTFILES_DIR"
fi

# --- hand off to make ----------------------------------------------

if ! command -v make >/dev/null 2>&1; then
  echo "make not found — installing..."
  if command -v brew >/dev/null 2>&1; then brew install make
  elif command -v apt >/dev/null 2>&1; then sudo apt install -y make
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y make
  fi
fi

cd "$DOTFILES_DIR"

# Now that deps.conf exists, TARGET can be validated. It's either a make target
# we know, or the name of a section in the manifest.
case "$TARGET" in
  install|link)
    make "$TARGET"
    ;;
  *)
    if ! grep -qE "^\[$TARGET\]" deps.conf; then
      echo ""
      echo "Unknown DOTFILES_TARGET: $TARGET"
      echo "Expected 'install', 'link', or a section in deps.conf:"
      sed -nE 's/^\[([A-Za-z0-9_-]+)\].*/  \1/p' deps.conf
      exit 1
    fi
    make install "$TARGET"
    ;;
esac

echo ""
echo "-------------------------------------------"
echo "Bootstrap complete. Restart your shell."
echo ""
