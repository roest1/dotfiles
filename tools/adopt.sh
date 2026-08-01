#!/usr/bin/env bash
# ─── Authoring aid: print a deps.conf line for a command ─────────────────────
#
#   ./tools/adopt.sh rg fd prettierd
#
#   tool  pkg          rg           ripgrep
#   tool  pkg          fd           fd-find
#   tool  npm          prettierd    @fsouza/prettierd
#
# Deliberately NOT a make target. Everything in the Makefile is about
# *operating* the repo — install, link, check, status, test. This is about
# *editing* it: an occasional aid for writing a manifest line, not part of any
# lifecycle. It was also the only target whose arguments weren't section names,
# which forced a special case in the Makefile for no real benefit.
#
# What it's for: the two parts of a manifest line that are easy to get wrong.
#
#   * which provider owns a command (asks rpm/dpkg/brew/mise/uv, not the path)
#   * the package name, which often differs from the command:
#       rg -> ripgrep   fd -> fd-find   nvim -> neovim
#       prettierd -> @fsouza/prettierd  (scoped npm packages)
#
# You name the commands. There is no "adopt everything installed" mode: nothing
# here can tell a dotfiles dependency from a project-scoped tool, so bulk output
# would be a list to vet by hand while nudging you to declare things you don't
# want rebuilt on every machine.
#
# Prints to stdout; never edits deps.conf. Which section a tool belongs in is a
# judgement call, and silently appending to the file that defines every machine
# you own is not a thing a script should do.

HERE_ADOPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/status.sh
source "$HERE_ADOPT/../lib/status.sh"

# Package name for a command, given its provider. Falls back to the command
# name, which is correct more often than not.
resolve_package() {
  local cmd="$1" provider="$2"
  local path resolved pkg

  path="$(command -v "$cmd" 2>/dev/null)" || { echo "$cmd"; return; }
  resolved="$(readlink -f "$path" 2>/dev/null || echo "$path")"

  case "$provider" in
    pkg)
      if command -v rpm >/dev/null 2>&1; then
        pkg="$(rpm -qf --qf '%{NAME}' "$resolved" 2>/dev/null)"
      elif command -v dpkg >/dev/null 2>&1; then
        pkg="$(dpkg -S "$resolved" 2>/dev/null | cut -d: -f1)"
      fi
      ;;
    npm)
      # npm's parseable output ends in the package directory. Scoped packages
      # live one level deeper (.../node_modules/@fsouza/prettierd), and the
      # scope is part of the name you have to install.
      local line base parent
      while IFS= read -r line; do
        base="$(basename "$line")"
        parent="$(basename "$(dirname "$line")")"
        if [[ "$base" == "$cmd" || "$base" == *"$cmd"* ]]; then
          if [[ "$parent" == @* ]]; then pkg="$parent/$base"; else pkg="$base"; fi
          break
        fi
      done < <(npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2)
      ;;
    cargo)
      pkg="$(cargo install --list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}' \
             | grep -xF "$cmd" | head -1)"
      ;;
    uv)
      pkg="$(uv tool list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}' \
             | grep -xF "$cmd" | head -1)"
      ;;
  esac

  # Only emit a package column when it actually differs from the command.
  if [[ -n "$pkg" && "$pkg" != "$cmd" ]]; then echo "$pkg"; else echo ""; fi
}

# Emit a manifest line for one command.
_adopt_line() {
  local cmd="$1" provider pkg

  provider="$(provider_of "$cmd")"

  if [[ "$provider" == "absent" ]]; then
    echo "# $cmd — not installed; can't tell which provider should own it"
    return 1
  fi

  pkg="$(resolve_package "$cmd" "$provider")"

  if [[ "$provider" == "manual" ]]; then
    printf 'tool  %-12s %-12s # installed outside any manager (%s)\n' \
      "pkg||manual" "$cmd" "$(command -v "$cmd" | sed "s|^$HOME|~|")"
    return 0
  fi

  if [[ -n "$pkg" ]]; then
    printf 'tool  %-12s %-12s %s\n' "$provider" "$cmd" "$pkg"
  else
    printf 'tool  %-12s %s\n' "$provider" "$cmd"
  fi
}

adopt_tool() {
  if [[ $# -eq 0 ]]; then
    cat >&2 <<'EOF'
usage: ./tools/adopt.sh <command>...

Name the commands you want declared, then paste the output into the right
section of deps.conf.

There is no "adopt everything installed" mode: nothing here can tell a dotfiles
dependency from a project-scoped tool, so bulk output would be a list to vet by
hand — while nudging you to declare things you don't want rebuilt everywhere.
EOF
    return 1
  fi
  echo "# paste into the right section of deps.conf:"
  echo ""
  local c
  for c in "$@"; do _adopt_line "$c" || true; done
  echo ""
}

# Runnable directly; still sourceable if you want the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  adopt_tool "$@"
fi
