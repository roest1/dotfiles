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

# uv is NOT installed here, and the absence is deliberate. It moved to its own
# [uv] section, because this section may not depend on a curl-piped installer
# (see CONTRIBUTING.md) and uv can no longer come from `pkg` — the distro build
# has `uv self update` compiled out. `make install` sweeps [uv] too, so a normal
# machine is unaffected; a machine that opts out of [uv] loses exactly
# 2parquet/2feather/2pickle, which guard on `command -v uv` and say so.

# WSL: clip.exe, and every other .exe, stops running when a package upgrade
# restarts systemd-binfmt. See ensure_wsl_interop in lib/pkg.sh. Never fatal —
# a guest without sudo still gets the rest of this file.
ensure_wsl_interop || true

# ── fzf version floor ────────────────────────────────────────────────────────
#
# Same shape as the neovim floor in nvim/deps.sh, for the same reason: apt
# carries 0.29 (Ubuntu 22.04) and 0.44 (24.04), deps.conf says `mise||pkg` so
# a fresh box lands a current fzf, but provider_install's `command -v`
# short-circuit means a box that ALREADY has the distro's keeps it. This is
# where that gets caught: upgrade through the distro if it can reach the floor
# (one binary, the whole point), else install a current one through mise over
# the top.
#
# THE NUMBER IS NOW INHERITED, NOT DERIVED, and that is a loose end rather
# than a decision. 0.65 was the floor because `github` needed it — --listen
# for live previews, the start/focus events, --style and --footer for the
# chrome. That github is gone; it is a Rust binary (tui/github) and needs no
# fzf at all. What is left using fzf is `__fzf_menu` and `__fzf_list` in
# bash_productivity, and between them they use --disabled, --bind, --header,
# --no-info and --expect — all far older flags, so the real floor is far
# lower, and `--no-info` is probably the binding one.
#
# It is deliberately NOT lowered in the same commit that removed the reason
# for it. Picking the new number means knowing which release introduced
# `--no-info`, and this repo does not guess at version/feature mappings --
# `wezterm/MIN_VERSION` was deleted for inferring render behaviour from a
# build stamp. Until that is measured, the cost of being too high is one
# unnecessary mise install on a box whose distro fzf would have done; the cost
# of guessing too low is every menu in the shell breaking on an old box, which
# is the wrong direction to be wrong in.
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
echo "  fzf (menus need >= $FZF_MIN_MAJOR.$FZF_MIN_MINOR):"
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
      echo "  ❌ could not upgrade fzf. The fzf menus may misbehave on $_fzf_v;"
      echo "     the rest of the shell is unaffected. By hand: mise use -g fzf@latest"
    }
  fi
else
  echo "  ✅ fzf $_fzf_v"
fi
