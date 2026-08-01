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
# Two entry points:
#
#   adopt_tool <cmd>...   emit a line for each named command
#   adopt_orphans         emit lines for everything installed via a tool manager
#                         but missing from the manifest (the `make status`
#                         orphans list, turned into pasteable config)
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
  [[ $# -gt 0 ]] || { echo "usage: make adopt <command>..." >&2; return 1; }
  echo "# paste into the right section of deps.conf:"
  echo ""
  local c
  for c in "$@"; do _adopt_line "$c" || true; done
  echo ""
}

# Everything a tool manager installed that the manifest doesn't declare.
adopt_orphans() {
  local declared
  declared="$(manifest_lines tool | cut -f3 | sort -u)"

  local -a candidates=()
  if command -v cargo >/dev/null 2>&1; then
    mapfile -t -O "${#candidates[@]}" candidates < <(cargo install --list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}')
  fi
  if command -v uv >/dev/null 2>&1; then
    mapfile -t -O "${#candidates[@]}" candidates < <(uv tool list 2>/dev/null | grep -E '^[a-zA-Z]' | awk '{print $1}')
  fi
  if command -v mise >/dev/null 2>&1; then
    mapfile -t -O "${#candidates[@]}" candidates < <(mise ls --installed 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z]')
  fi
  if command -v npm >/dev/null 2>&1; then
    mapfile -t -O "${#candidates[@]}" candidates < <(npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -r -n1 basename)
  fi

  local found=0 c
  for c in "${candidates[@]}"; do
    [[ -z "$c" ]] && continue
    grep -qxF "$c" <<<"$declared" && continue
    command -v "$c" >/dev/null 2>&1 || continue
    if [[ $found -eq 0 ]]; then
      echo "# installed via a tool manager but not in deps.conf —"
      echo "# paste whichever of these you want rebuilt on a fresh machine:"
      echo ""
      found=1
    fi
    _adopt_line "$c" || true
  done

  if [[ $found -eq 0 ]]; then
    echo "# no orphans — everything installed via a tool manager is declared"
  fi
  echo ""
}
