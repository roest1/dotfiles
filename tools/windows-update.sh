#!/usr/bin/env bash
set -euo pipefail

# ─── Update the Windows host's clone, from inside WSL ────────────────────────
#
# The host clone is the piece of this setup that goes stale, and the reason is
# ergonomic rather than technical: you are never sitting in it. Every wezterm
# symptom chased during the Windows bring-up traced back to that clone being on
# an older commit, or to `install.ps1` not having been re-run after a pull that
# added a link or a font.
#
# So this runs the whole update from the side you ARE on. WSL can launch Windows
# binaries through interop, and wslpath translates the paths, which is all this
# needs -- there is no daemon and nothing to keep in sync.
#
# It does NOT get folded into `make install`. That would make the common case
# spawn a Windows process and touch a 9p mount, and a Linux-only machine would
# pay for a host it does not have.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

if ! is_wsl; then
  echo "Not running under WSL — there is no Windows host clone to update from here."
  echo "On the host itself, run:  .\\windows\\install.ps1"
  exit 0
fi

# --- locate the clone ------------------------------------------------------

win="${DOTFILES_WINDOWS_DIR:-}"
if [ -z "$win" ]; then
  for d in /mnt/c/Users/*/dotfiles; do
    [ -d "$d/.git" ] && { win="$d"; break; }
  done
fi

if [ -z "$win" ] || [ ! -d "$win/.git" ]; then
  echo "No Windows clone found under /mnt/c/Users/*/dotfiles."
  echo ""
  echo "  If you use the Windows host, create it once from PowerShell:"
  echo "    irm https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.ps1 | iex"
  echo ""
  echo "  Set DOTFILES_WINDOWS_DIR if your clone is somewhere else."
  exit 1
fi

echo "Windows clone: $win"

# --- find powershell -------------------------------------------------------
#
# Not `command -v powershell.exe`: whether System32 is on PATH depends on
# interop's appendWindowsPath setting, which people turn off to keep PATH clean.
# The binary is at a fixed location, so look there first and only fall back to
# PATH.
ps_exe=""
for candidate in \
  "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
  "$(command -v powershell.exe 2>/dev/null || true)"
do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { ps_exe="$candidate"; break; }
done

if [ -z "$ps_exe" ]; then
  echo "Could not find powershell.exe. Is WSL interop disabled?"
  echo "  Check /etc/wsl.conf for [interop] enabled=false"
  exit 1
fi

# --- line endings ----------------------------------------------------------
#
# A clone checked out before .gitattributes pinned eol=lf still holds CRLF, and
# git refuses to pull over it. Distinguishing "only line endings" from real edits
# is the whole point: --ignore-cr-at-eol answers exactly that, so a tree that is
# clean under it can be renormalized without asking, and one that is not gets
# left alone.
if ! git -C "$win" diff --quiet 2>/dev/null; then
  if git -C "$win" diff --quiet --ignore-cr-at-eol 2>/dev/null; then
    echo "  line endings only (CRLF) — renormalizing"
    git -C "$win" add --renormalize . >/dev/null 2>&1 || true
    git -C "$win" checkout -- . >/dev/null 2>&1 || true
  else
    echo ""
    echo "  The Windows clone has real local changes. Not touching it."
    git -C "$win" status --short | head -10
    exit 1
  fi
fi

# --- update ----------------------------------------------------------------

branch="$(git -C "$win" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if [ "$branch" != "main" ]; then
  echo "  on '$branch' — switching to main"
  git -C "$win" checkout main
fi

echo "  pulling..."
git -C "$win" pull --ff-only

# --- install ---------------------------------------------------------------
#
# -RepoRoot is passed explicitly. install.ps1 defaults it from $PSScriptRoot,
# which is correct when a Windows shell runs it, but this is launched with a
# Linux working directory and there is no reason to make it guess.
win_path="$(wslpath -w "$win")"
echo ""
"$ps_exe" -NoProfile -ExecutionPolicy Bypass \
  -File "${win_path}\\windows\\install.ps1" -RepoRoot "$win_path"
