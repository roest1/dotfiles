#!/usr/bin/env bash
set -euo pipefail

# ─── [bash] platform fixups ──────────────────────────────────────────────────
#
# The tools themselves are declared in deps.conf. This file exists only for
# things that are genuinely conditional on the platform and can't be expressed
# as a manifest line without inventing a DSL for `if`.
#
# Run automatically after the [bash] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

# macOS ships bash 3.2; this config wants 5.x. Not a manifest line because it
# applies only to brew.
if [ "$PM" = "brew" ]; then
  pkg_install "bash"
fi

# Debian/Ubuntu install these under different binary names than everyone else.
# The manifest asks for `fd` and `bat`; apt delivers `fdfind` and `batcat`.
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ensure_symlink "fdfind" "fd"
fi
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  ensure_symlink "batcat" "bat"
fi

# zoxide: Fedora packages it, base RHEL does not. The manifest declares `pkg`
# because that's right nearly everywhere; this catches the case where the
# package genuinely doesn't exist. Runs only if the providers already failed.
if ! command -v zoxide >/dev/null 2>&1; then
  echo "  ➡️  zoxide not packaged here — using the official installer..."
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

# uv: same shape as zoxide. Fedora and Homebrew package it; Ubuntu 24.04 does
# not, so `pkg` alone leaves 2parquet/2feather/2pickle unusable there. This is
# the same installer lib/pkg.sh already curls when it needs uv to install a uv
# tool — declaring `uv` as a tool in its own right just means it now happens
# whether or not something else pulled it in first.
if ! command -v uv >/dev/null 2>&1; then
  echo "  ➡️  uv not packaged here — using the official installer..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ── fzf version floor ────────────────────────────────────────────────────────
#
# Same shape as the neovim floor in nvim/deps.sh, for the same reason. github
# (bash_github_tui) is built on fzf features that arrived between 0.36 and
# 0.65 — --listen for live previews, the start/focus events, --style and
# --footer for the chrome — and apt carries 0.29 (Ubuntu 22.04) and 0.44
# (24.04). deps.conf now says `mise||pkg`, which lands a current fzf on a
# fresh box, but provider_install's `command -v` short-circuit means a box
# that ALREADY has the distro's fzf keeps it. This is where that gets caught:
# upgrade through the distro if it can reach the floor (one binary, the
# whole point), else install a current one through mise over the top.
#
# The floor is 0.65 (Aug 2025). github checks it too and refuses with the
# same instruction, so a stale machine says why rather than half-working.
FZF_MIN_MAJOR=0
FZF_MIN_MINOR=65

fzf_version() {
  command -v fzf >/dev/null 2>&1 || return 0
  fzf --version 2>/dev/null | awk '{ print $1 }'
}

fzf_below_floor() {
  local v="$1" maj min rest
  [ -n "$v" ] || return 1
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  maj="${maj//[!0-9]/}"; min="${min//[!0-9]/}"
  [ -n "$maj" ] || return 1
  [ -n "$min" ] || min=0
  if [ "$maj" -lt "$FZF_MIN_MAJOR" ]; then return 0; fi
  if [ "$maj" -eq "$FZF_MIN_MAJOR" ] && [ "$min" -lt "$FZF_MIN_MINOR" ]; then return 0; fi
  return 1
}

echo ""
echo "  fzf (github needs >= $FZF_MIN_MAJOR.$FZF_MIN_MINOR):"
_fzf_v="$(fzf_version)"
if [ -z "$_fzf_v" ]; then
  echo "  ⚠️  fzf not installed — the [bash] tools should have provided it"
elif fzf_below_floor "$_fzf_v"; then
  echo "  ↩︎  found $_fzf_v, below the floor"
  if [ -n "${PM:-}" ] && pkg_upgrade fzf; then
    _fzf_v="$(fzf_version)"
    if ! fzf_below_floor "$_fzf_v"; then
      echo "  ✅ $PM upgraded it to $_fzf_v — no second install needed"
    fi
  fi
  if fzf_below_floor "$(fzf_version)"; then
    echo "  ➡️  $PM can't reach the floor — installing a current fzf via mise"
    mise_install_forced fzf || {
      echo "  ❌ could not upgrade fzf. github will refuse to start on $_fzf_v;"
      echo "     the rest of the shell is unaffected. By hand: mise use -g fzf@latest"
    }
  fi
else
  echo "  ✅ fzf $_fzf_v"
fi
