#!/usr/bin/env bash
# ─── Manifest line generator ─────────────────────────────────────────────────
#
# Writes deps.conf lines for you. Deliberately NOT a "scan the machine and
# generate everything" tool: this box has 2203 installed packages and dnf5 no
# longer exposes which were explicitly asked for, so that flavour would emit a
# firehose you'd have to hand-filter — worse than typing the line yourself.
#
# It does the parts that are actually fiddly and error-prone:
#
#   * which provider owns this command (asks rpm/dpkg/brew/mise/uv, not the path)
#   * the package name, which often differs from the command:
#       rg -> ripgrep   fd -> fd-find   nvim -> neovim
#       prettierd -> @fsouza/prettierd  (scoped npm packages)
#
#   adopt_tool <cmd>...   emit a line for each named command
#
# You name the commands. There is no bulk mode on purpose: a tool manager can't
# tell a dotfiles dependency from a project-scoped one, so "adopt everything
# installed" would just be a list to vet by hand — while nudging you to declare
# things you don't want rebuilt everywhere. `make status` reports orphans; the
# decision (adopt, or record an `ignore` line) stays yours.
#
# Output goes to stdout as pasteable manifest lines. It never edits deps.conf —
# where a tool belongs is a judgement call, and silently appending to the file
# that defines every machine you own is not a thing a script should do.

HERE_ADOPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./status.sh
source "$HERE_ADOPT/status.sh"

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
usage: make adopt <command>...

Name the commands you want declared. There is deliberately no "adopt everything
installed" mode: a tool manager can't tell a dotfiles dependency from a
project-scoped one, so bulk output would be a list you'd have to vet by hand
anyway — and it would nudge you toward declaring things you don't want rebuilt
on every machine.

`make status` reports orphans (installed, not declared). Decide per tool:
adopt it here, or record the decision with an `ignore` line in deps.conf.
EOF
    return 1
  fi
  echo "# paste into the right section of deps.conf:"
  echo ""
  local c
  for c in "$@"; do _adopt_line "$c" || true; done
  echo ""
}
