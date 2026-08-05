#!/usr/bin/env bash
# ─── Section runner ──────────────────────────────────────────────────────────
#
# Installs the tools for one or more manifest sections, then runs their `post`
# commands. install.sh handles the `link` lines; this handles `tool` and `post`.
#
#   run_tools  [section...]     install tools (all sections if none given)
#   run_post   [section...]     run post commands
#   run_check  [section...]     verify tools are present; non-zero if any missing

HERE_RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./manifest.sh
source "$HERE_RUN/manifest.sh"
# shellcheck source=./providers.sh
source "$HERE_RUN/providers.sh"

run_tools() {
  pkg_detect
  ensure_local_bin_on_path

  local current="" section provider cmd pkg
  local ran_any=0

  while IFS=$'\t' read -r section provider cmd pkg; do
    [[ -z "$section" ]] && continue
    if [[ "$section" != "$current" ]]; then
      current="$section"
      echo ""
      echo "[$section]"
      echo "-------------------------------------------"
    fi
    provider_install "$provider" "$cmd" "$pkg" || true
    ran_any=1
  done < <(manifest_lines tool "$@")

  [[ $ran_any -eq 0 ]] && echo "  (no tools enabled)"

  run_hooks "$@"
  return 0
}

# Per-section escape hatch: <section>/deps.sh, run after that section's tools.
#
# The manifest covers the declarative ~90%. The rest is genuinely conditional —
# apt installing fd as `fdfind`, dnf needing clang-devel for bindgen, WSL
# detecting a clipboard backend — and forcing that into a table would mean
# inventing a DSL to express `if`. A script is the honest shape for it.
run_hooks() {
  local sections=("$@") s
  if [[ ${#sections[@]} -eq 0 ]]; then
    mapfile -t sections < <(manifest_sections)
  fi
  for s in "${sections[@]}"; do
    local hook="$HERE_RUN/../$s/deps.sh"
    if [[ -f "$hook" ]]; then
      echo ""
      echo "[$s] platform fixups"
      echo "-------------------------------------------"
      # shellcheck disable=SC1090
      bash "$hook" || echo "  ⚠️  $s/deps.sh failed"
    fi
  done
}

run_post() {
  local section cmdline
  while IFS=$'\t' read -r section cmdline; do
    [[ -z "$cmdline" ]] && continue
    echo ""
    echo "[$section] post: $cmdline"
    echo "-------------------------------------------"
    ( cd "$HERE_RUN/.." && eval "$cmdline" ) || echo "  ⚠️  post step failed: $cmdline"
  done < <(manifest_lines post "$@")
}

# Verify every enabled tool resolves. Commented-out lines are absent from the
# manifest output, so a disabled tool is never reported MISSING — that's what
# makes the node toggle produce a clean check rather than a wall of failures.
run_check() {
  local current="" section provider cmd pkg missing=0 section_missing=0

  while IFS=$'\t' read -r section provider cmd pkg; do
    [[ -z "$section" ]] && continue
    if [[ "$section" != "$current" ]]; then
      if [[ -n "$current" ]]; then
        [[ $section_missing -eq 0 ]] && echo "  all present" || echo "  run 'make install $current'"
      fi
      current="$section"
      section_missing=0
      echo ""
      echo "[$section]"
      echo "-------------------------------------------"
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
      printf "  %-14s ok\n" "$cmd"
    elif [[ "$cmd" == "bat" ]] && command -v batcat >/dev/null 2>&1; then
      printf "  %-14s ok (batcat)\n" "$cmd"
    elif [[ "$cmd" == "fd" ]] && command -v fdfind >/dev/null 2>&1; then
      printf "  %-14s ok (fdfind)\n" "$cmd"
    else
      printf "  %-14s MISSING\n" "$cmd"
      missing=$((missing + 1))
      section_missing=1
    fi
  done < <(manifest_lines tool "$@")

  if [[ -n "$current" ]]; then
    [[ $section_missing -eq 0 ]] && echo "  all present" || echo "  run 'make install $current'"
  fi

  echo ""
  return $(( missing > 0 ? 1 : 0 ))
}
