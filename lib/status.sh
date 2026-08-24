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
# For is_wsl / tool_applies_here: a tool that belongs to the Windows host is not
# drift when you are looking at it from inside the WSL guest.
# shellcheck source=./pkg.sh
source "$HERE_STATUS/pkg.sh"
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
STATUS_DRIFT_FONTS=0

_drift_link()  { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_LINKS=$((STATUS_DRIFT_LINKS + 1)); }
_drift_tool()  { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_TOOLS=$((STATUS_DRIFT_TOOLS + 1)); }
_drift_stale() { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_STALE=$((STATUS_DRIFT_STALE + 1)); }
_drift_windows() { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_WINDOWS=$((STATUS_DRIFT_WINDOWS + 1)); }
_drift_font()  { STATUS_DRIFT=$((STATUS_DRIFT + 1)); STATUS_DRIFT_FONTS=$((STATUS_DRIFT_FONTS + 1)); }

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

    # `manual` is a WILDCARD, deliberately. It does not name a provider -- it
    # says "this repo cannot install this; an official installer or an extracted
    # build is an acceptable source." So any provenance satisfies it, which is
    # exactly what it was added for: declaring `manual` is what stops
    # `make status` flagging a correct state as drift.
    #
    # Without this, [tui]'s `manual cargo` and `manual font` sat in the drift
    # count permanently. Both are built by tui/deps.sh with
    # `cargo install --path`, which lands them in ~/.cargo/bin, which
    # provider_of correctly reports as "cargo" -- a true answer the declaration
    # was never disagreeing with.
    #
    # This only applies to a tool that IS installed: an absent one is caught by
    # the `absent` branch in status_tools before provider_satisfies is reached.
    [[ "$p" == "manual" ]] && return 0
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

    if ! tool_applies_here "$cmd"; then
      printf "%s  · %-14s n/a — installed on the Windows host%s\n" "$SG" "$cmd" "$SG_OFF"
    elif [[ "$actual" == "absent" ]]; then
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
# ─── The Windows host clone, seen from the WSL guest ─────────────────────────
#
# The one piece of state `make status` could not previously see, and the one
# that goes stale most often. wezterm.exe reads a SECOND clone on C:, and you
# are almost never sitting in it -- so it falls behind main while the WSL clone
# you do live in is current. Every wezterm symptom chased this week turned out
# to be that: a host clone on an older commit, missing a link or a font the
# guest had had for hours.
#
# Found by glob rather than by asking Windows. `powershell.exe $env:USERPROFILE`
# costs a process launch across the VM boundary on every `make status`, and
# wslvar needs wslu installed. The glob is local, instant, and wrong only on a
# box with several Windows profiles -- which DOTFILES_WINDOWS_DIR overrides.
#
# Reports the COMMIT, not the working tree. A clone on C: legitimately shows
# modified files to the guest's git when line endings disagree, and that is a
# different problem with a different fix (.gitattributes) -- flagging it here
# would cry wolf on every run.
status_windows() {
  is_wsl || return 0

  local win="${DOTFILES_WINDOWS_DIR:-}"
  if [[ -z "$win" ]]; then
    local d
    for d in /mnt/c/Users/*/dotfiles; do
      [[ -d "$d/.git" ]] && { win="$d"; break; }
    done
  fi

  echo ""
  printf "%s[windows] host clone%s\n" "$SG_B" "$SG_OFF"

  if [[ -z "$win" || ! -d "$win/.git" ]]; then
    printf "%s  · not found under /mnt/c/Users/*/dotfiles%s\n" "$SG" "$SG_OFF"
    echo "      wezterm.exe reads its config from a clone on C:. If you use the"
    echo "      Windows host, see windows/README.md; if you do not, ignore this."
    return 0
  fi

  # Compared against origin/main, NOT this clone's HEAD. You are frequently on
  # a feature branch here, and the host clone being "different from my branch"
  # is not news -- what matters is whether it has what shipped.
  #
  # Uses the origin/main ref as of the last fetch rather than asking the
  # network: `make status` is a local question and should not block on a remote.
  local want have branch
  want="$(git -C "$DOTFILES_ROOT" rev-parse origin/main 2>/dev/null)"
  have="$(git -C "$win" rev-parse HEAD 2>/dev/null)"
  branch="$(git -C "$win" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [[ -z "$have" ]]; then
    printf "%s  ✗ [out of date]  cannot read HEAD in %s%s\n" "$SG" "$win" "$SG_OFF"
    _drift_windows
    return 0
  fi

  if [[ -z "$want" ]]; then
    printf "%s  · [unknown]      no origin/main here to compare against%s\n" "$SG" "$SG_OFF"
    return 0
  fi

  if [[ "$have" == "$want" ]]; then
    printf "%s  ✓ [up to date]   %s @ %s%s\n" "$SG" "${branch:-detached}" "${have:0:7}" "$SG_OFF"
    return 0
  fi

  printf "%s  ✗ [out of date]  %s @ %s — origin/main is %s%s\n" \
    "$SG" "${branch:-detached}" "${have:0:7}" "${want:0:7}" "$SG_OFF"
  _drift_windows
}

# ── Font lanes ───────────────────────────────────────────────────────────────
#
# The [wezterm] question the manifest cannot answer: the links can all be right
# and the lanes still render in the base font.
#
# This used to be a version floor -- wezterm/MIN_VERSION, a build stamp compared
# on every install. It inferred a render-time behavior from a number, which is
# not inferable, and it could not fail safe: every build at or above the floor
# passed untested, so the silent failure it existed to catch survived inside its
# own green tick.
#
# What is here instead splits the question at the line of what is knowable:
#
#   provable    the font files exist where font_dirs points, and what wezterm
#               actually resolved the family to. These count as drift.
#   not         whether the binary APPLIES font_rules on the blink attribute at
#               draw time. Nothing can read that but an eye, so `font show`
#               prints the carrier and this counts nothing for it.
#
# Belongs to [wezterm] rather than [tui] because the subject is wezterm's font
# lanes; `font` is only the implementation that answers, the same way bash calls
# into the picker rather than carrying a second copy of "measure a font".
status_fonts() {
  # Scope exactly as status_links does, by asking the manifest rather than
  # inventing a second rule: no arguments means every section, so this runs on a
  # bare `make status` and is skipped by `make status bash`.
  local section _rest in_scope=0
  while IFS=$'\t' read -r section _rest; do
    [[ "$section" == wezterm ]] && { in_scope=1; break; }
  done < <(manifest_lines link "$@")
  [[ $in_scope -eq 1 ]] || return 0

  echo ""
  printf "%s[wezterm] fonts%s\n" "$SG_B" "$SG_OFF"

  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/wezterm/fonts"
  local shown="${dir/#$HOME/\~}"

  # font_dirs reads this path, so an empty or absent directory is the whole
  # mechanism gone -- and a link can point at a directory that has nothing in
  # it, which status_links cannot see because the link itself is correct.
  local ttfs=0
  if [[ -d "$dir" ]]; then
    ttfs=$(find -L "$dir" -maxdepth 1 -name '*.ttf' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [[ "$ttfs" -gt 0 ]]; then
    printf "%s  ✓ %-38s %s font file(s)%s\n" "$SG" "$shown" "$ttfs" "$SG_OFF"
  else
    printf "%s  ✗ %-38s no font files — run 'make link'%s\n" "$SG" "$shown" "$SG_OFF"
    _drift_font
  fi

  status_fonts_resolution "$dir"

  # `font` belongs to [tui], which is a section a machine may legitimately not
  # have selected. Absent is reported, never counted: an opt-out is not drift.
  if command -v font >/dev/null 2>&1; then
    font show || _drift_font
  else
    printf "%s  · lanes not shown — the 'font' picker is not installed%s\n" "$SG" "$SG_OFF"
    echo "      It lives in [tui]. Add tui to ~/.config/dotfiles/sections, or"
    echo "      run 'make install tui'."
  fi
}

# What wezterm RESOLVED the carrier family to, which is the one failure a
# correct config still produces: two files claiming 'Science Gothic Mono'
# resolve by first match, and the loser is silently the wrong glyphs. That cost
# an afternoon once, and no amount of reading wezterm.lua would have shown it.
#
# Deliberately tolerant of ls-fonts' output FORMAT. It asks one question -- did
# the family resolve to a file under the linked directory -- by looking for that
# path anywhere in the output, rather than parsing columns that upstream is free
# to rearrange. A brittle parser here would fail closed on a machine that is
# fine, which is the failure mode this whole block exists to stop repeating.
status_fonts_resolution() {
  local dir="$1"

  # Under WSL there is no wezterm in the guest ON PURPOSE -- wezterm.exe runs on
  # the host and draws the pixels, so the guest has no binary to ask. Not drift.
  if is_wsl; then
    printf "%s  · resolution not checked — wezterm.exe is on the Windows host%s\n" "$SG" "$SG_OFF"
    return 0
  fi

  if ! command -v wezterm >/dev/null 2>&1; then
    printf "%s  · resolution not checked — wezterm is not installed here%s\n" "$SG" "$SG_OFF"
    return 0
  fi

  local out
  # Bare `ls-fonts`, which is what prints the rule list with each resolved file
  # path in a comment. There is no --rules flag -- the flags are --list-system,
  # --text, --codepoints and --rasterize-ascii -- and asking for one would make
  # this exit non-zero and report "said nothing" on every machine.
  out="$(wezterm ls-fonts 2>/dev/null)"
  if [[ -z "$out" ]]; then
    printf "%s  · resolution not checked — 'wezterm ls-fonts' said nothing%s\n" "$SG" "$SG_OFF"
    return 0
  fi

  if [[ "$out" != *"Science Gothic Mono"* ]]; then
    printf "%s  ✗ font_rules never mention Science Gothic Mono%s\n" "$SG" "$SG_OFF"
    echo "      wezterm is reading a config that is not this repo's. Check that"
    echo "      ~/.config/wezterm/wezterm.lua links here, then restart wezterm —"
    echo "      a running process does not pick up a pulled config."
    _drift_font
    return 0
  fi

  if [[ "$out" == *"$dir"* ]]; then
    printf "%s  ✓ Science Gothic Mono resolves inside the linked font dir%s\n" "$SG" "$SG_OFF"
  else
    printf "%s  ✗ Science Gothic Mono resolves OUTSIDE the linked font dir%s\n" "$SG" "$SG_OFF"
    echo "      A system-installed copy is shadowing the one in this repo. Two"
    echo "      files claiming the same family resolve by first match and the"
    echo "      loser is silent. Remove the other copy — these fonts are meant"
    echo "      to be read via font_dirs, never installed into the font path."
    _drift_font
  fi
}

status_all() {
  STATUS_DRIFT=0
  STATUS_DRIFT_LINKS=0
  STATUS_DRIFT_TOOLS=0
  STATUS_DRIFT_STALE=0
  STATUS_DRIFT_WINDOWS=0
  STATUS_DRIFT_FONTS=0
  echo ""
  printf "%ssync status — deps.conf vs. this machine%s\n" "$SG_B" "$SG_OFF"
  printf "%s===========================================%s\n" "$SG_B" "$SG_OFF"
  status_links "$@"
  status_tools "$@"
  status_fonts "$@"
  status_windows
  STATUS_DRIFT=$(( STATUS_DRIFT_LINKS + STATUS_DRIFT_TOOLS + STATUS_DRIFT_STALE \
                   + STATUS_DRIFT_WINDOWS + STATUS_DRIFT_FONTS ))

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
    if [[ $STATUS_DRIFT_WINDOWS -gt 0 ]]; then
      echo "  ✗ windows ($STATUS_DRIFT_WINDOWS) — the host clone wezterm.exe reads is behind origin/main."
      echo "             Fix it from here:"
      echo "               make windows"
      echo "             That pulls the host clone and re-runs its installer, which is"
      echo "             not optional when an update added a link or a font."
    fi
    if [[ $STATUS_DRIFT_FONTS -gt 0 ]]; then
      echo "  ✗ fonts ($STATUS_DRIFT_FONTS) — the font lanes cannot work as configured."
      echo "             Only the provable half is counted here: files present, and"
      echo "             what wezterm resolved. Whether the binary APPLIES the rule"
      echo "             is the carrier line above — that one is for your eyes."
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
