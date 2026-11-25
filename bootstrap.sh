#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# ~/dotfiles/bootstrap.sh — one-line entry point for a fresh machine
#
#   curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
#
# Solves the chicken-and-egg: you need the repo before you can run
# anything in it. Installs git if missing, clones over HTTPS (the repo is
# public, so the core needs no key and no login), then hands off to make.
#
# If ~/.config/dotfiles/plugins lists a plugin on GitHub over SSH and GitHub
# does not accept a key from this machine yet, it runs `gh auth login` first:
# that one login generates the key and uploads it, so the plugin clones in the
# same `make install`. Without such a line, no login is asked for.
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
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git
  else
    echo "No dnf: this repo targets Fedora and RHEL. Install git manually."
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
  # Submodules too: the prompt (ps1/) is one, and a fresh machine should
  # not need a second step to get it.
  git clone --recurse-submodules "$REPO_URL" "$DOTFILES_DIR"
fi

# --- hand off to make ----------------------------------------------

if ! command -v make >/dev/null 2>&1; then
  echo "make not found — installing..."
  command -v dnf >/dev/null 2>&1 && sudo dnf install -y make
fi

cd "$DOTFILES_DIR"

# --- a login, only for a machine that asked for a private plugin ---------
#
# The one sign-in this script can need, and only when the machine asked for it:
# a line in the plugins file naming a GitHub repo over SSH, and GitHub not yet
# accepting a key from here. `gh auth login -p ssh` makes the key and uploads
# it, so the plugin clones in the `make install` below and not in a second run.

PLUGINS_FILE="${DOTFILES_PLUGINS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/plugins}"

# GitHub answers `ssh -T` with exit status 1 even when it accepts the key, so
# the ANSWER is read and the status is not. Not `ssh | grep -q`: under
# `set -o pipefail` ssh's 1 is the pipeline's status whatever grep found, which
# asked a machine with a working key to log in again on every run.
#
# accept-new records GitHub's host key on first contact. That is what lets the
# plugin clone, which has no terminal to ask "are you sure" on, go through.
github_accepts_key() {
  command -v ssh >/dev/null 2>&1 || return 1
  local said
  said=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -T git@github.com 2>&1) || true
  [[ $said == *"successfully authenticated"* ]]
}

# Under `curl | bash` stdin is the script, so gh has to be given the terminal.
# Opened, not tested with -r: /dev/tty is readable by its permissions on a
# machine with no terminal at all, and fails only when opened.
has_terminal() { { : </dev/tty; } 2>/dev/null; }

if [[ "$TARGET" == install && -f "$PLUGINS_FILE" ]] &&
  grep -qE '^[^#]*git@github\.com' "$PLUGINS_FILE" && ! github_accepts_key; then
  echo ""
  echo "A plugin in ${PLUGINS_FILE/#$HOME/\~} is on GitHub over SSH, and GitHub"
  echo "does not accept a key from this machine yet."
  # gh is in [bash]. The section is installed again by `make install` below,
  # which finds everything there and is quick.
  make install bash || echo "  the bash section did not install cleanly"
  if ! command -v gh >/dev/null 2>&1; then
    echo "  gh is not installed — the plugin will be skipped. Afterwards:"
    echo "    gh auth login -h github.com -p ssh && make install"
  elif ! has_terminal; then
    echo "  no terminal to log in on — the plugin will be skipped. Afterwards:"
    echo "    gh auth login -h github.com -p ssh && make install"
  else
    echo ""
    echo "Logging in with gh. Say YES to generating an SSH key: gh uploads it."
    echo "If it asks to authenticate Git with your GitHub credentials, say NO."
    if gh auth login -h github.com -p ssh </dev/tty && github_accepts_key; then
      echo "  GitHub accepts this machine's key."
      # gh took the admin:public_key scope to upload the key and keeps it. A
      # token that can add keys to the account is not one to leave lying in a
      # keyring, so it is handed back (git/GITHUB_SETUP.md does the same).
      if gh auth status -h github.com 2>&1 | grep -q 'admin:public_key'; then
        echo "  One more confirmation, to take back the scope that upload needed."
        gh auth refresh -h github.com -r admin:public_key </dev/tty ||
          echo "  not taken back. By hand: gh auth refresh -h github.com -r admin:public_key"
      fi
    else
      echo "  GitHub still does not accept a key from this machine — the plugin"
      echo "  will be skipped. Afterwards: gh auth login -h github.com -p ssh && make install"
    fi
  fi
fi

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
