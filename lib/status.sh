#!/usr/bin/env bash
# ─── Sync status: declared state vs. live machine ────────────────────────────
#
# `make check` answers one question — "does this command exist?" — and that turns
# out to be a weak question. It reports ok for a tool that's installed by a
# completely different provider than deps.conf declares, which means the manifest
# can drift into describing a machine you don't actually have. A fresh box built
# from a drifted manifest gets different software than the one you're sitting at.
#
# This is the stronger question, in three parts:
#
#   links     is ~/.bashrc a symlink into THIS repo, or something else?
#   tools     was this installed by the provider the manifest declares?
#   orphans   is something installed that the manifest doesn't know about?
#
# Provenance is answered by asking each package manager rather than guessing from
# the path, because $HOME/.local/bin is genuinely ambiguous — a uv shim, an apt
# rename symlink (fdfind -> fd), and a hand-dropped binary all live there.

HERE_STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$HERE_STATUS/.." && pwd)"
# shellcheck source=./manifest.sh
source "$HERE_STATUS/manifest.sh"

STATUS_DRIFT=0

# ── Provenance ───────────────────────────────────────────────────────────────
#
# Returns one of: pkg cargo npm uv mise bun manual unknown
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
    "$HOME"/.npm-global/*) echo "npm";   return ;;
    *"/mise/"*)            echo "mise";  return ;;
    # bun's own installer lands in ~/.bun — same category as zoxide's curl
    # installer or an extracted wezterm: outside any package manager.
    "$HOME"/.bun/*)        echo "manual"; return ;;
  esac

  # System package managers own it?
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$resolved" >/dev/null 2>&1; then echo "pkg"; return; fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -S "$resolved" >/dev/null 2>&1; then echo "pkg"; return; fi
  if command -v brew >/dev/null 2>&1 && [[ "$resolved" == *"/Cellar/"* ]]; then echo "pkg"; return; fi

  # npm's global prefix isn't always ~/.npm-global
  if command -v npm >/dev/null 2>&1; then
    local npm_bin
    npm_bin="$(npm prefix -g 2>/dev/null)/bin"
    [[ "$resolved" == "$npm_bin"/* ]] && { echo "npm"; return; }
  fi

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
        STATUS_DRIFT=$((STATUS_DRIFT + 1))
      fi
    elif [[ -e "$dest" ]]; then
      printf "  ✗ %-38s is a real file, not a link into this repo\n" "${dest/#$HOME/\~}"
      STATUS_DRIFT=$((STATUS_DRIFT + 1))
    else
      printf "  · %-38s not linked (run: make link)\n" "${dest/#$HOME/\~}"
      STATUS_DRIFT=$((STATUS_DRIFT + 1))
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
      STATUS_DRIFT=$((STATUS_DRIFT + 1))
    elif provider_satisfies "$provider" "$actual"; then
      printf "  ✓ %-14s %s\n" "$cmd" "$actual"
    else
      printf "  ✗ %-14s declared %-12s actual %-8s %s\n" \
        "$cmd" "$provider" "$actual" "$(command -v "$cmd" | sed "s|^$HOME|~|")"
      STATUS_DRIFT=$((STATUS_DRIFT + 1))
    fi
  done < <(manifest_lines tool "$@")
}

# ── Orphans ──────────────────────────────────────────────────────────────────
#
# Installed through a tool manager but absent from the manifest. Informational,
# not drift: plenty of legitimate things live outside this repo. It's here to
# answer "what would I lose rebuilding this machine from deps.conf alone?"
status_orphans() {
  local declared ignored
  declared="$(manifest_lines tool | cut -f3 | sort -u)"
  # Commands explicitly marked as not-ours. A tool manager can't tell a dotfiles
  # dependency from a project-scoped one — only you can — so `ignore` lines in
  # deps.conf record that judgement instead of re-reporting it every run.
  ignored="$(manifest_lines ignore | cut -f2 | sort -u)"

  echo ""
  echo "[orphans] installed but not declared"

  local found=0
  _orphan_report() {
    local label="$1"; shift
    local item
    for item in "$@"; do
      [[ -z "$item" ]] && continue
      grep -qxF "$item" <<<"$declared" && continue
      grep -qxF "$item" <<<"$ignored" && continue
      printf "  ? %-14s via %s\n" "$item" "$label"
      found=1
    done
  }

  if command -v cargo >/dev/null 2>&1; then
    mapfile -t c < <(cargo install --list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}')
    _orphan_report cargo "${c[@]}"
  fi
  if command -v uv >/dev/null 2>&1; then
    mapfile -t u < <(uv tool list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}')
    _orphan_report uv "${u[@]}"
  fi
  if command -v mise >/dev/null 2>&1; then
    mapfile -t m < <(mise ls --installed 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z]')
    _orphan_report mise "${m[@]}"
  fi
  if command -v npm >/dev/null 2>&1; then
    mapfile -t n < <(npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -r -n1 basename)
    _orphan_report "npm -g" "${n[@]}"
  fi

  [[ $found -eq 0 ]] && echo "  none"
  return 0
}

# ── Everything ───────────────────────────────────────────────────────────────
status_all() {
  STATUS_DRIFT=0
  echo ""
  echo "sync status — deps.conf vs. this machine"
  echo "==========================================="
  status_links "$@"
  status_tools "$@"
  status_orphans

  echo ""
  echo "==========================================="
  if [[ $STATUS_DRIFT -eq 0 ]]; then
    echo "in sync"
  else
    echo "$STATUS_DRIFT item(s) out of sync"
    echo ""
    echo "  ✗ links  — run 'make link' to repoint them"
    echo "  ✗ tools  — the manifest declares a provider that didn't install it."
    echo "             Either fix deps.conf to match reality, or uninstall and"
    echo "             re-run 'make install' to get the declared one."
  fi
  echo ""
  return $(( STATUS_DRIFT > 0 ? 1 : 0 ))
}
