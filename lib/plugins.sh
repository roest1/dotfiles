#!/usr/bin/env bash
# ─── Plugins: other repos run through this engine ────────────────────────────
#
# A plugin is a git repo with its own deps.conf in this repo's format, plus any
# <section>/deps.sh it needs. Nothing here knows what a plugin contains: it
# clones the repo and runs the same install.sh / run.sh / status.sh over its
# manifest, with MANIFEST_FILE pointing into the clone. So a plugin's link,
# tool and post lines mean exactly what they mean here.
#
# Which plugins a machine uses is MACHINE-LOCAL, for the reason
# ~/.config/dotfiles/sections is: this repo is public, and the list names
# private repos. It lives in $HOME, never in the work tree:
#
#   ~/.config/dotfiles/plugins
#     # name   git-url                              [clone dir]
#     roest    git@github.com:roest1/roest.git      ~/roest
#
# The clone dir defaults to ~/.local/share/dotfiles/plugins/<name>, which suits
# a plugin you only consume. Give a path for one you edit.
#
# The core works with ZERO plugins: no file means no plugins, and a plugin that
# cannot be cloned -- no access, no network -- is skipped with a message, never
# fatal. A friend installing this repo must not trip over a repo they cannot
# read.
#
#   plugins_fetch          clone any listed plugin that is not cloned yet
#   plugins_run <verb>     link | install | check | status, over every clone

HERE_PLUGINS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_CORE="$(cd "$HERE_PLUGINS/.." && pwd)"
DOTFILES_PLUGINS_FILE="${DOTFILES_PLUGINS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/plugins}"
DOTFILES_PLUGIN_HOME="${DOTFILES_PLUGIN_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/plugins}"

# One record per plugin: name<TAB>url<TAB>dir. Comments and blank lines are
# skipped the way deps.conf's are; a malformed line warns on stderr and is
# skipped rather than guessed at.
plugins_list() {
  [[ -f "$DOTFILES_PLUGINS_FILE" ]] || return 0
  local raw line name url dir extra
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    read -r name url dir extra <<<"$line"
    [[ -z "$name" ]] && continue
    if [[ -z "$url" || -n "$extra" || ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "warning: $DOTFILES_PLUGINS_FILE: cannot read '$raw' (want: name url [dir])" >&2
      continue
    fi
    dir="${dir:-$DOTFILES_PLUGIN_HOME/$name}"
    dir="${dir/#\~/$HOME}"
    printf '%s\t%s\t%s\n' "$name" "$url" "$dir"
  done < "$DOTFILES_PLUGINS_FILE"
}

# Clone what is missing. Never pulls: `make install` does not pull this repo
# either, and updating is a separate, deliberate step.
plugins_fetch() {
  local name url dir
  while IFS=$'\t' read -r name url dir; do
    if [[ -d "$dir/.git" ]]; then
      continue
    elif [[ -e "$dir" ]]; then
      echo "  ⚠️  plugin $name: $dir exists and is not a git clone — skipped"
      continue
    fi
    echo "  ➡️  cloning plugin $name -> ${dir/#$HOME/\~}"
    if ! git clone --quiet "$url" "$dir" 2>/dev/null; then
      echo "  ↷  plugin $name: could not clone $url (no access, or offline) — skipped"
    fi
  done < <(plugins_list)
}

# Run one verb over every cloned plugin, each in its own subshell so one
# plugin's MANIFEST_FILE can never leak into the next or back into the core.
#
# DOTFILES_SECTIONS_FILE is set EMPTY for the plugin: this machine's sections
# file names core sections, and read against a plugin's manifest it would
# select none of them (see lib/manifest.sh). To skip a plugin, remove its line.
plugins_run() {
  local verb="$1" name url dir rc=0
  while IFS=$'\t' read -r name url dir; do
    [[ -d "$dir" ]] || continue
    if [[ ! -f "$dir/deps.conf" ]]; then
      echo "  ⚠️  plugin $name: no deps.conf in ${dir/#$HOME/\~} — skipped"
      continue
    fi
    echo ""
    echo "═══ plugin: $name (${dir/#$HOME/\~}) ═══"
    (
      export MANIFEST_FILE="$dir/deps.conf" DOTFILES_SECTIONS_FILE=""
      case "$verb" in
        link)    bash "$DOTFILES_CORE/install.sh" ;;
        # No check here: `make install` runs `make check` last, which covers
        # plugins, and `make plugins` asks for it separately.
        install) DOTFILES_FETCH_SUBMODULES=1 bash "$DOTFILES_CORE/install.sh" &&
                   bash -c 'source "$0/lib/run.sh" && run_tools && run_post' "$DOTFILES_CORE" ;;
        check)   bash -c 'source "$0/lib/run.sh" && run_check' "$DOTFILES_CORE" ;;
        status)  bash -c 'source "$0/lib/status.sh" && STATUS_DRIFT=0 && status_links && status_tools &&
                          (( STATUS_DRIFT == 0 ))' "$DOTFILES_CORE" ;;
        *)       echo "plugins_run: unknown verb $verb" >&2; exit 2 ;;
      esac
    ) || rc=1
  done < <(plugins_list)
  return $rc
}
