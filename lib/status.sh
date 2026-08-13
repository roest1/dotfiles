#!/usr/bin/env bash
# ─── Sync status: declared state vs. live machine ────────────────────────────
#
# `make check` answers one question — "does this command exist?" — and that turns
# out to be a weak question. It reports ok for a tool that's installed by a
# completely different provider than deps.conf declares, which means the manifest
# can drift into describing a machine you don't actually have. A fresh box built
# from a drifted manifest gets different software than the one you're sitting at.
#
# This is the stronger question, in two parts:
#
#   links     is ~/.bashrc a symlink into THIS repo, or something else?
#   tools     was this installed by the provider the manifest declares?
#
# Deliberately does NOT report "installed but not declared". Nothing here can
# tell a dotfiles dependency from a project-scoped tool, so that list is mostly
# noise — and suppressing the noise meant naming unrelated projects inside the
# file that defines every machine you own. This repo describes itself, nothing
# else. Ask `uv tool list` / `cargo install --list` directly on the rare
# occasions you want that inventory.
#
# Provenance is answered by asking each package manager rather than guessing from
# the path, because $HOME/.local/bin is genuinely ambiguous — a uv shim, an apt
# rename symlink (fdfind -> fd), and a hand-dropped binary all live there.

HERE_STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$HERE_STATUS/.." && pwd)"
# shellcheck source=./manifest.sh
source "$HERE_STATUS/manifest.sh"

# STATUS_DRIFT is the total, and is what callers outside this file read
# (ci.yml asserts on it after calling status_links alone). The two halves are
# tracked separately so the summary can name the half that actually drifted —
# it used to print both remediation lines for any drift at all, so a machine
# with one mismatched tool provider was told to re-run `make link` about links
# that were every one of them fine. A status command that misreports which
# thing is wrong is worse than no status command.
STATUS_DRIFT=0
STATUS_DRIFT_LINKS=0
STATUS_DRIFT_TOOLS=0

_drift_link() { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_LINKS=$((STATUS_DRIFT_LINKS + 1)); }
_drift_tool() { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_TOOLS=$((STATUS_DRIFT_TOOLS + 1)); }

# ── Provenance ───────────────────────────────────────────────────────────────
#
# Returns one of: pkg cargo uv mise bun manual unknown
provider_of() {
  local cmd="$1"
  local path resolved

  path="$(command -v "$cmd" 2>/dev/null)" || { echo "absent"; return; }
  resolved="$(readlink -f "$path" 2>/dev/null || echo "$path")"

  # Ask the tool managers directly — authoritative, unlike path guessing.
  if command -v mise >/dev/null 2>&1; then
    if mise which "$cmd" >/dev/null 2>&1; then echo "mise"; return; fi
  fi
  if command -v uv >/dev/null 2>&1; then
    if uv tool list 2>/dev/null | grep -qE "^${cmd}\b|^- ${cmd}\b"; then echo "uv"; return; fi
  fi

  case "$resolved" in
    "$HOME"/.cargo/bin/*)  echo "cargo"; return ;;
    *"/mise/"*)            echo "mise";  return ;;
    # bun's own installer lands in ~/.bun — same category as zoxide's curl
    # installer or an extracted wezterm: outside any package manager.
    "$HOME"/.bun/*)        echo "manual"; return ;;
  esac

  # System package managers own it?
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$resolved" >/dev/null 2>&1; then echo "pkg"; return; fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$resolved" >/dev/null 2>&1; then echo "pkg"; return; fi
  if command -v brew >/dev/null 2>&1 && [[ "$resolved" == *"/Cellar/"* ]]; then echo "pkg"; return; fi


  case "$resolved" in
    /usr/bin/*|/usr/local/bin/*|/opt/homebrew/*) echo "pkg" ;;
    *) echo "manual" ;;
  esac
}

# Does the actual provider satisfy the declared spec? A `||` chain is satisfied
# by any member — `pkg||cargo` declares either as acceptable, so neither is drift.
provider_satisfies() {
  local spec="$1" actual="$2" p
  for p in ${spec//||/ }; do
    [[ "$p" == "$actual" ]] && return 0
  done
  return 1
}

# ── Links ────────────────────────────────────────────────────────────────────
status_links() {
  local section src dest current="" target
  while IFS=$'\t' read -r section src dest; do
    [[ -z "$section" ]] && continue
    if [[ "$section" != "$current" ]]; then
      current="$section"; echo ""; echo "[$section] links"
    fi

    target="$DOTFILES_ROOT/$src"

    if [[ -L "$dest" ]]; then
      local actual; actual="$(readlink "$dest")"
      if [[ "$actual" == "$target" ]]; then
        printf "  ✓ %-38s\n" "${dest/#$HOME/\~}"
      else
        printf "  ✗ %-38s points at %s\n" "${dest/#$HOME/\~}" "${actual/#$HOME/\~}"
        _drift_link
      fi
    elif [[ -e "$dest" ]]; then
      printf "  ✗ %-38s is a real file, not a link into this repo\n" "${dest/#$HOME/\~}"
      _drift_link
    else
      printf "  · %-38s not linked (run: make link)\n" "${dest/#$HOME/\~}"
      _drift_link
    fi
  done < <(manifest_lines link "$@")
}

# ── Tools ────────────────────────────────────────────────────────────────────
status_tools() {
  local section provider cmd pkg current="" actual
  # shellcheck disable=SC2034  # pkg is read to consume the 4th field
  while IFS=$'\t' read -r section provider cmd pkg; do
    [[ -z "$section" ]] && continue
    if [[ "$section" != "$current" ]]; then
      current="$section"; echo ""; echo "[$section] tools"
    fi

    actual="$(provider_of "$cmd")"

    if [[ "$actual" == "absent" ]]; then
      printf "  · %-14s not installed (declared %s)\n" "$cmd" "$provider"
      _drift_tool
    elif provider_satisfies "$provider" "$actual"; then
      printf "  ✓ %-14s %s\n" "$cmd" "$actual"
    else
      printf "  ✗ %-14s declared %-12s actual %-8s %s\n" \
        "$cmd" "$provider" "$actual" "$(command -v "$cmd" | sed "s|^$HOME|~|")"
      _drift_tool
    fi
  done < <(manifest_lines tool "$@")
}

# ── Everything ───────────────────────────────────────────────────────────────
status_all() {
  STATUS_DRIFT=0
  STATUS_DRIFT_LINKS=0
  STATUS_DRIFT_TOOLS=0
  echo ""
  echo "sync status — deps.conf vs. this machine"
  echo "==========================================="
  status_links "$@"
  status_tools "$@"
  STATUS_DRIFT=$(( STATUS_DRIFT_LINKS + STATUS_DRIFT_TOOLS ))

  echo ""
  echo "==========================================="
  if [[ $STATUS_DRIFT -eq 0 ]]; then
    echo "in sync"
  else
    echo "$STATUS_DRIFT item(s) out of sync"
    echo ""
    if [[ $STATUS_DRIFT_LINKS -gt 0 ]]; then
      echo "  ✗ links ($STATUS_DRIFT_LINKS) — run 'make link' to repoint them"
    fi
    if [[ $STATUS_DRIFT_TOOLS -gt 0 ]]; then
      echo "  ✗ tools ($STATUS_DRIFT_TOOLS) — the manifest declares a provider that didn't install it."
      echo "             Either fix deps.conf to match reality, or uninstall and"
      echo "             re-run 'make install' to get the declared one."
    fi
  fi
  echo ""
  return $(( STATUS_DRIFT > 0 ? 1 : 0 ))
}
