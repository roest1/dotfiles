#!/usr/bin/env bash
set -euo pipefail

# ─── [uv] platform fixups ────────────────────────────────────────────────────
#
# deps.conf declares `manual uv`, which installs nothing by itself — that is
# what `manual` means. This is where the real install happens, and it is one
# call: ensure_uv (lib/pkg.sh), which prefers Astral's installer over the distro
# package because only that build can `uv self update`. The reasoning is in
# [uv] in deps.conf; the ordering is in ensure_uv. Neither belongs here.
#
# What this file adds is the half a provider cannot express: noticing that the
# machine already has a uv that came from somewhere else, and saying so.
#
# Run automatically after the [uv] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

ensure_uv || {
  echo "  ❌ uv could not be installed. By hand:"
  echo "       curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 0   # not fatal: run_hooks only warns, and nothing else here depends on it
}

# ── Is the uv on this machine one that can update itself? ────────────────────
#
# ensure_uv short-circuits on `command -v`, deliberately — installing a second
# copy over a distro one is how the mess in docs/decisions/tool-duplication.md
# gets made, not how it gets fixed. So a machine that already had the distro's
# uv when this section first ran keeps it, silently, forever. This is the check
# that stops that being silent.
#
# It reports and never removes. `dnf remove` needs sudo, the package may be a
# dependency of something else, and a dotfiles repo that uninstalls system
# packages is a different class of program than one that installs into $HOME —
# the same line the decision doc draws. One command, printed, for you to run.

# Every uv on PATH, resolved and de-duplicated, in PATH order.
#
# Hand-split rather than `type -aP uv` or an IFS=: loop: macOS ships bash 3.2
# and this file runs there in the install job, so the plainest spelling wins.
# Duplicated PATH entries are real (a .bashrc that prepends twice), hence the
# de-dupe on the RESOLVED path — two entries pointing at one binary is not two
# copies of uv.
uv_paths() {
  local rest="$PATH" dir resolved seen=$'\n'
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    if [ "$dir" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
    [ -n "$dir" ] || dir="."
    [ -x "$dir/uv" ] || continue
    # `readlink -f` guarded rather than assumed: it is GNU-shaped, and the
    # macOS jobs are the whole of this repo's macOS support claim. The fallback
    # is the unresolved path, which every test below tolerates.
    resolved="$(readlink -f "$dir/uv" 2>/dev/null || echo "$dir/uv")"
    case "$seen" in
      *$'\n'"$resolved"$'\n'*) continue ;;
    esac
    seen="$seen$resolved"$'\n'
    printf '%s\n' "$resolved"
  done
}

# Does a system package manager own this binary? The same three questions
# lib/status.sh's provider_of asks, in the same order.
uv_is_packaged() {
  local path="$1"
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$path" >/dev/null 2>&1; then return 0; fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$path" >/dev/null 2>&1; then return 0; fi
  case "$path" in */Cellar/*) return 0 ;; esac
  return 1
}

# Can THIS binary update itself? uv answers that from the receipt Astral's
# installer writes, so ask the same file rather than guessing from the path.
# ~/.local/bin is also where `pip install --user uv` puts its copy — on RHEL
# that one was reported ✅ here while `uv self update` refused it, because the
# checks above only know rpm, dpkg and brew.
#
# The receipt names the directory it installed into, and that has to be the
# directory of the binary that runs: a receipt left over from a removed
# install, or a pipx symlink resolving into its venv, must not count.
uv_receipt() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv-receipt.json"
}

uv_has_receipt() {
  local dir receipt prefix
  dir="$(dirname "$1")"
  receipt="$(uv_receipt)"
  [ -r "$receipt" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    prefix="$(jq -r '.install_prefix // empty' "$receipt" 2>/dev/null)"
  else
    # [uv] does not depend on [bash], so jq may be absent. The receipt is
    # cargo-dist's compact JSON; this reads the one field this needs.
    prefix="$(sed -n 's/.*"install_prefix": *"\([^"]*\)".*/\1/p' "$receipt")"
  fi
  [ -n "$prefix" ] && [ "$prefix" = "$dir" ]
}

uv_remove_hint() {
  case "$PM" in
    dnf)  echo "sudo dnf remove uv" ;;
    apt)  echo "sudo apt remove uv" ;;
    brew) echo "brew uninstall uv" ;;
    *)    echo "remove it with your package manager" ;;
  esac
}

echo ""
echo "  uv (must be able to 'uv self update'):"

active=""
packaged=""
copies=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  copies=$((copies + 1))
  [ -n "$active" ] || active="$path"
  if uv_is_packaged "$path"; then
    packaged="${packaged}${packaged:+, }${path}"
  fi
done < <(uv_paths)

version="$(uv --version 2>/dev/null || echo 'version unknown')"
shown="${active/#$HOME/\~}"
shown_receipt="$(uv_receipt)"; shown_receipt="${shown_receipt/#$HOME/\~}"

if [ "$copies" -eq 0 ]; then
  # ensure_uv said yes and PATH says no. A shell function or alias shadowing
  # the binary is the only way here, and guessing which is worse than saying so.
  echo "  ⚠️  uv answers to 'command -v' but is not a file on PATH — skipping"
elif [ -z "$packaged" ] && ! uv_has_receipt "$active"; then
  # No package manager owns it, and Astral's installer did not put it there
  # either: pip --user, pipx or a hand-copied binary. Which one is not
  # knowable from here, so name the likely two and stop guessing.
  echo "  ⚠️  $version — $shown"
  echo "      not from Astral's installer (no receipt for this directory in"
  echo "      ${shown_receipt}), so 'uv self update' refuses it."
  echo ""
  echo "      Most likely pip --user or pipx, which also install here:"
  echo "        python3 -m pip show uv    # or: pipx list"
  echo "      Remove it with whichever owns it, then:"
  echo "        make install uv"
  echo "        hash -r    # in any shell that has already run uv"
elif [ -z "$packaged" ]; then
  echo "  ✅ $version — $shown"
  if [ "$copies" -gt 1 ]; then
    echo "  ⚠️  $copies copies on PATH; none from a package manager, so this"
    echo "      repo cannot tell you which is stale. 'uv self update' only"
    echo "      ever updates $shown."
  fi
elif uv_is_packaged "$active"; then
  # The distro's copy is the one that RUNS. This is the state that prompted the
  # section: `uv self version` and `uvx` can disagree about which uv you have,
  # and `uv self update` refuses outright.
  echo "  ⚠️  the active uv is a distro package and cannot update itself"
  echo "      $shown  ($version)"
  echo ""
  echo "      Remove it, then re-run to get the self-updatable one:"
  echo "        $(uv_remove_hint)"
  echo "        make install uv"
  echo "        hash -r    # in any shell that has already run uv"
  echo ""
  echo "      That last one is not optional in a shell you are keeping. Bash"
  echo "      caches the full path of every command it runs and does NOT"
  echo "      re-search when the file disappears — it keeps the dead entry and"
  echo "      exits 127. Until the cache is cleared, 'uv' in this shell reports"
  echo "      'No such file or directory' rather than finding the new one."
  echo ""
  echo "      That also deletes /etc/uv/uv.toml, which is where"
  echo "      python-downloads and python-preference came from. Fine:"
  echo "      ~/.config/uv/uv.toml is this repo's copy and outranks it anyway."
else
  # Both kinds are here. Which one WINS is not knowable from this process and
  # is not claimed: ensure_local_bin_on_path has already prepended
  # ~/.local/bin, an interactive shell may order PATH differently, and bash's
  # hash table can pin a copy that PATH order says lost. That last one is how
  # this was found — `uv self version` reported 0.11.32 from a cached
  # /usr/bin/uv while `uvx uvhow`, which resolves PATH itself, correctly
  # reported 0.12.9 in ~/.local/bin. Two tools disagreeing, both right.
  #
  # The remedy does not depend on the answer, so state what is true and stop.
  echo "  ⚠️  two uvs on this machine, one of them a distro package:"
  echo "      $shown  ($version here, self-updatable)"
  echo "      $packaged  (cannot 'uv self update')"
  echo ""
  echo "      Which one your shell runs depends on PATH order and on bash's"
  echo "      command hash, so 'uv self version' can disagree with 'uvx uvhow'."
  echo "      Remove the packaged one — it is the older of the two and the"
  echo "      only one that cannot fix that itself:"
  echo "        $(uv_remove_hint)"
  echo "      Then 'hash -r' in any shell that already ran uv: bash caches the"
  echo "      path it resolved and will keep using the removed one, exiting 127."
fi
