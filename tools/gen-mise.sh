#!/usr/bin/env bash
# Generate mise.toml from deps.conf.
#
# WHY THIS EXISTS
#
# deps.conf declares *what* to install and *which provider* may install it.
# It deliberately says nothing about versions — a version column on every line
# would be noise on the dozen tools that come from apt or dnf, where the distro
# picks the version and that is the whole point of using it.
#
# But the mise-provided tools had no version anywhere. lib/pkg.sh ran
# `mise use -g "$tool@latest"`, and the resolved version landed in
# ~/.config/mise/config.toml — untracked, machine-local, outside the repo. Two
# machines provisioned a month apart got different software and nothing here
# recorded it, while CLAUDE.md claimed versions were pinned.
#
# So: deps.conf stays the single source of truth for the tool *set*, this
# script derives mise.toml from it, and `mise lock` turns that into mise.lock
# with per-platform checksums. Exactly the bun.lock / yarn.lock arrangement
# already used on the nvim side — one authored file, one generated file, and
# CI asserting they agree.
#
# mise.toml is GENERATED. Do not hand-edit the tool list; add or remove the
# tool in deps.conf and re-run `make mise-lock`. Versions ARE yours to edit:
# an existing pin is always preserved, and only new tools get resolved to the
# current latest.
#
#   ./tools/gen-mise.sh          write mise.toml
#   ./tools/gen-mise.sh --check  exit 1 if it would differ (used by CI)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/mise.toml"

# shellcheck source=../lib/manifest.sh
source "$ROOT/lib/manifest.sh"

# Existing pin for a tool, if mise.toml already has one. Preserving these is
# what makes the generator safe to re-run: regenerating must never silently
# bump a version you deliberately chose.
#
# Matched literally with awk, not with sed: a backend-qualified key
# ("aqua:neovim/neovim") carries the `/` sed would take as its delimiter.
existing_pin() {
  local tool="$1" version
  [[ -f "$OUT" ]] || return 1
  version="$(awk -v t="$tool" '
    { key = $0; sub(/[ \t]*=.*/, "", key); gsub(/"/, "", key) }
    key == t && match($0, /= *"[^"]*"/) {
      v = substr($0, RSTART, RLENGTH); sub(/^= *"/, "", v); sub(/"$/, "", v); print v; exit
    }' "$OUT")"
  [[ -n "$version" ]] || return 1
  echo "$version"
}

# The key a tool is pinned under: its registry name, unless the registry's
# DEFAULT backend for it records no checksum and an aqua backend exists.
#
# The lockfile is only a supply-chain control for backends that write a hash
# into it. aqua and core do; vfox and asdf plugins do not. Found 2026-11-09:
# every tool in mise.lock had a sha256 except neovim, whose registry default
# is vfox:mise-plugins/vfox-neovim, so the one binary this repo most depends
# on was the one installed unchecked. Same upstream tarball either way
# (github.com/neovim/neovim/releases), only aqua hashes it.
#
# A rule rather than a neovim special case, so the next tool whose registry
# default is a plugin is caught the same way.
mise_key() {
  local name="$1" backends first aqua
  backends="$(mise registry "$name" 2>/dev/null || true)"
  first="${backends%% *}"
  case "$first" in
    aqua:*|core:*|"") echo "$name"; return ;;
  esac
  aqua="$(tr ' ' '\n' <<<"$backends" | grep -m1 '^aqua:' || true)"
  echo "${aqua:-$name}"
}

# mise's registry name is not reliably either field of a deps.conf tool line.
# `nvim neovim` is `neovim` to mise (the package field), but
# `tree-sitter tree-sitter-cli` is `tree-sitter` (the command) — tree-sitter-cli
# is what cargo and dnf call it, and mise has no such entry. Asking the registry
# is the only correct answer; guessing a field is how the existing
# `mise use -g tree-sitter-cli` in lib/pkg.sh silently never worked.
mise_name() {
  local cmd="$1" pkg="$2" candidate
  for candidate in "${pkg:-$cmd}" "$cmd"; do
    [[ -z "$candidate" ]] && continue
    if mise latest "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

mise_tools() {
  # A tool belongs here if `mise` appears anywhere in its provider chain —
  # including as a last resort (`pkg||cargo||mise`). If mise ends up being the
  # one that installs it, the version should be pinned regardless of where in
  # the chain it sat.
  while IFS=$'\t' read -r _section provider cmd pkg; do
    [[ ",${provider//||/,}," == *",mise,"* ]] || continue
    mise_name "$cmd" "$pkg" || echo "  ! mise has no registry entry for '${pkg:-$cmd}' — skipping" >&2
  done < <(manifest_lines tool) | sort -u
}

# Highest version mise has actually installed, ignoring entries it reports as
# missing. Preferred over `mise latest` because it records the state this
# machine is known to work in — and because `latest` is not even monotonic:
# qsv 22.0.1 was installed from `@latest`, while the registry currently reports
# 21.1.0 as latest. Pinning to a resolved-today value would have been a silent
# downgrade of a working tool.
installed_version() {
  local tool="$1"
  mise ls "$tool" 2>/dev/null \
    | grep -v missing \
    | awk '{print $2}' \
    | grep -E '^[0-9]' \
    | sort -V | tail -1
}

generate() {
  local tool key version
  {
    echo "# @generated by tools/gen-mise.sh from deps.conf — do not edit the tool list."
    echo "#"
    echo "# Add or remove tools in deps.conf, then run: make mise-lock"
    echo "# Versions here are yours to change; regenerating preserves them."
    echo "# Checksums and per-platform URLs live in mise.lock."
    echo ""
    echo "[tools]"
    while read -r tool; do
      [[ -z "$tool" ]] && continue
      # Order matters: a pin you chose, then what this machine actually runs,
      # then the registry's current latest for a tool nobody has installed yet.
      # The bare name's pin still counts when the key changes, so moving a
      # tool to a checksummed backend does not also silently bump it.
      key="$(mise_key "$tool")"
      version="$(existing_pin "$key" || existing_pin "$tool" || true)"
      [[ -n "$version" ]] || version="$(installed_version "$key")"
      [[ -n "$version" ]] || version="$(mise latest "$key" 2>/dev/null || true)"
      if [[ -z "$version" ]]; then
        echo "  ! could not resolve a version for '$tool' — skipping" >&2
        continue
      fi
      if [[ "$key" == *:* ]]; then
        printf '"%s" = "%s"\n' "$key" "$version"
      else
        printf '%s = "%s"\n' "$key" "$version"
      fi
    done < <(mise_tools)
  }
}

if [[ "${1:-}" == "--check" ]]; then
  # Deliberately registry-free, so this runs on a CI box with no mise: it
  # compares the tool SET both ways without asking mise to resolve anything.
  # Versions are not compared — a bump is a legitimate committed change, while
  # a tool in one file and not the other means the two have drifted apart.
  [[ -f "$OUT" ]] || { echo "mise.toml is missing — run: make mise-lock" >&2; exit 1; }

  # Keys compared by tool name: "aqua:neovim/neovim" pins neovim.
  pinned="$(sed -n 's/^"\{0,1\}\([A-Za-z0-9_.@/:-]*\)"\{0,1\} = ".*"$/\1/p' "$OUT" \
    | sed 's/^[^:]*://; s|^.*/||' | sort -u)"
  bad=0

  # Every mise-capable tool in deps.conf is pinned under one of its two names.
  while IFS=$'\t' read -r _section provider cmd pkg; do
    [[ ",${provider//||/,}," == *",mise,"* ]] || continue
    if ! echo "$pinned" | grep -qxE "$(printf '%s|%s' "${pkg:-$cmd}" "$cmd")"; then
      echo "deps.conf declares mise for '$cmd' but mise.toml pins no such tool" >&2
      bad=1
    fi
  done < <(manifest_lines tool)

  # ...and nothing is pinned that deps.conf no longer declares.
  declared="$(while IFS=$'\t' read -r _s provider cmd pkg; do
      [[ ",${provider//||/,}," == *",mise,"* ]] || continue
      echo "${pkg:-$cmd}"; echo "$cmd"
    done < <(manifest_lines tool) | sort -u)"
  while read -r tool; do
    [[ -z "$tool" ]] && continue
    echo "$declared" | grep -qx "$tool" || {
      echo "mise.toml pins '$tool', which deps.conf no longer declares" >&2; bad=1; }
  done <<<"$pinned"

  [[ $bad -eq 0 ]] || { echo "run: make mise-lock" >&2; exit 1; }
  echo "mise.toml matches deps.conf"

  # The lockfile is the point of the exercise; an unpinned tool set with no
  # checksums is the state this replaced.
  [[ -f "$ROOT/mise.lock" ]] || { echo "mise.lock is missing — run: make mise-lock" >&2; exit 1; }
  echo "mise.lock present"

  # ...and present is not the same as protective. A tool locked through a
  # plugin backend gets a URL and no hash, which installs whatever the URL
  # serves that day (neovim, until 2026-11-09; see mise_key). Every tool must
  # carry a sha256 for linux-x64, the one platform the whole fleet runs.
  unhashed="$(awk '
    /^\[\[tools\./ { tool = $0; sub(/^\[\[tools\./, "", tool); sub(/\]\]$/, "", tool); want[tool] = 1 }
    /"platforms\.linux-x64"\]$/ { cur = tool; next }
    /^\[/ { cur = "" }
    cur != "" && /^checksum = "sha256:/ { hashed[cur] = 1 }
    END { for (t in want) if (!(t in hashed)) print t }' "$ROOT/mise.lock")"
  if [[ -n "$unhashed" ]]; then
    echo "mise.lock has no linux-x64 checksum for: $(echo $unhashed)" >&2
    echo "pin it under an aqua: backend (tools/gen-mise.sh, mise_key), then: make mise-lock" >&2
    exit 1
  fi
  echo "mise.lock hashes every tool for linux-x64"
  exit 0
fi

command -v mise >/dev/null 2>&1 || {
  echo "mise is not installed — cannot resolve versions" >&2
  exit 1
}

generate > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "wrote $OUT"
