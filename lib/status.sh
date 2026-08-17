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
# Sets SG / SG_B / SG_OFF — all empty unless stdout is a WezTerm terminal, so
# the printf calls below interpolate them unconditionally and this file needs
# no branching. See lib/sgr.sh for why the guard has two halves.
# shellcheck source=./sgr.sh
source "$HERE_STATUS/sgr.sh"

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
STATUS_DRIFT_STALE=0

_drift_link()  { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_LINKS=$((STATUS_DRIFT_LINKS + 1)); }
_drift_tool()  { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_TOOLS=$((STATUS_DRIFT_TOOLS + 1)); }
_drift_stale() { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_STALE=$((STATUS_DRIFT_STALE + 1)); }

# ── Provenance ───────────────────────────────────────────────────────────────
#
# Returns one of: pkg cargo uv mise mise-stale bun manual unknown
provider_of() {
  local cmd="$1"
  local path resolved

  path="$(command -v "$cmd" 2>/dev/null)" || { echo "absent"; return; }
  resolved="$(readlink -f "$path" 2>/dev/null || echo "$path")"

  # Ask the tool managers directly — authoritative, unlike path guessing.
  if command -v mise >/dev/null 2>&1; then
    if mise which "$cmd" >/dev/null 2>&1; then echo "mise"; return; fi

    # A mise shim on PATH that `mise which` disowns is a *stale pin*, not a
    # foreign install. mise.toml names a version that was never installed
    # here, so the shim resolves to nothing mise will run — while `command -v`
    # still answers yes, which is why `make install` skips it (mise_install
    # short-circuits on exactly that). Distinguished because the remedy is
    # `mise install`; the old answer fell through to "manual" and sent you to
    # uninstall/reinstall a tool that was never manually installed.
    if [[ "$path" == */mise/shims/* ]]; then echo "mise-stale"; return; fi
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

# Wanted and installed versions for a stale pin, tab-separated.
#
# `mise ls <tool>` marks the pinned-but-absent version "(missing)"; anything
# else it lists is on disk. Both halves are worth printing — "pinned 22.0.1,
# active 21.1.0" says what one `mise install` will do, where a bare ✗ doesn't.
_mise_pin_versions() {
  local cmd="$1" want="" have="" line ver
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ver="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$line" in
      *"(missing)"*) want="${want:+$want,}$ver" ;;
      *)             have="${have:+$have,}$ver" ;;
    esac
  done < <(mise ls "$cmd" 2>/dev/null)
  printf '%s\t%s' "$want" "$have"
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
      current="$section"; echo ""; printf "%s[%s] links%s\n" "$SG_B" "$section" "$SG_OFF"
    fi

    target="$DOTFILES_ROOT/$src"

    if [[ -L "$dest" ]]; then
      local actual; actual="$(readlink "$dest")"
      if [[ "$actual" == "$target" ]]; then
        printf "%s  ✓ %-38s%s\n" "$SG" "${dest/#$HOME/\~}" "$SG_OFF"
      else
        printf "%s  ✗ %-38s points at %s%s\n" "$SG" "${dest/#$HOME/\~}" "${actual/#$HOME/\~}" "$SG_OFF"
        _drift_link
      fi
    elif [[ -e "$dest" ]]; then
      printf "%s  ✗ %-38s is a real file, not a link into this repo%s\n" "$SG" "${dest/#$HOME/\~}" "$SG_OFF"
      _drift_link
    else
      printf "%s  · %-38s not linked (run: make link)%s\n" "$SG" "${dest/#$HOME/\~}" "$SG_OFF"
      _drift_link
    fi
  done < <(manifest_lines link "$@")
}

# ── Tools ────────────────────────────────────────────────────────────────────
status_tools() {
  local section provider cmd pkg current="" actual want have
  # shellcheck disable=SC2034  # pkg is read to consume the 4th field
  while IFS=$'\t' read -r section provider cmd pkg; do
    [[ -z "$section" ]] && continue
    if [[ "$section" != "$current" ]]; then
      current="$section"; echo ""; printf "%s[%s] tools%s\n" "$SG_B" "$section" "$SG_OFF"
    fi

    actual="$(provider_of "$cmd")"

    if [[ "$actual" == "absent" ]]; then
      printf "%s  · %-14s not installed (declared %s)%s\n" "$SG" "$cmd" "$provider" "$SG_OFF"
      _drift_tool
    elif [[ "$actual" == "mise-stale" ]]; then
      IFS=$'\t' read -r want have <<<"$(_mise_pin_versions "$cmd")"
      printf "%s  ✗ %-14s pinned %s not installed (active: %s)%s\n" \
        "$SG" "$cmd" "${want:-?}" "${have:-none}" "$SG_OFF"
      _drift_stale
    elif provider_satisfies "$provider" "$actual"; then
      printf "%s  ✓ %-14s %s%s\n" "$SG" "$cmd" "$actual" "$SG_OFF"
    else
      printf "%s  ✗ %-14s declared %-12s actual %-8s %s%s\n" \
        "$SG" "$cmd" "$provider" "$actual" "$(command -v "$cmd" | sed "s|^$HOME|~|")" "$SG_OFF"
      _drift_tool
    fi
  done < <(manifest_lines tool "$@")
}

# ── Everything ───────────────────────────────────────────────────────────────
status_all() {
  STATUS_DRIFT=0
  STATUS_DRIFT_LINKS=0
  STATUS_DRIFT_TOOLS=0
  STATUS_DRIFT_STALE=0
  echo ""
  printf "%ssync status — deps.conf vs. this machine%s\n" "$SG_B" "$SG_OFF"
  printf "%s===========================================%s\n" "$SG_B" "$SG_OFF"
  status_links "$@"
  status_tools "$@"
  STATUS_DRIFT=$(( STATUS_DRIFT_LINKS + STATUS_DRIFT_TOOLS + STATUS_DRIFT_STALE ))

  echo ""
  printf "%s===========================================%s\n" "$SG_B" "$SG_OFF"
  if [[ $STATUS_DRIFT -eq 0 ]]; then
    printf "%sin sync%s\n" "$SG" "$SG_OFF"
  else
    printf "%s%s item(s) out of sync%s\n" "$SG" "$STATUS_DRIFT" "$SG_OFF"
    echo ""
    if [[ $STATUS_DRIFT_LINKS -gt 0 ]]; then
      echo "  ✗ links ($STATUS_DRIFT_LINKS) — run 'make link' to repoint them"
    fi
    if [[ $STATUS_DRIFT_STALE -gt 0 ]]; then
      echo "  ✗ pins ($STATUS_DRIFT_STALE) — mise.toml pins a version this machine never installed."
      echo "             Run 'mise install'. 'make install' will NOT fix it: the old"
      echo "             shim is still on PATH, so mise_install short-circuits."
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
