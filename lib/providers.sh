#!/usr/bin/env bash
# ─── Provider dispatch ───────────────────────────────────────────────────────
#
# Maps a provider name from deps.conf to an installer in lib/pkg.sh. This is the
# layer that keeps tool declarations as *data*: if this repo ever moves to Nix,
# it's a new case in provider_install, not a rewrite of the manifest.
#
# Providers support `||` fallback chains, tried left to right:
#   tool  pkg||cargo  eza      # distro package if it exists, else compile it
#
# That chain form is also the fix for provider selection that used to guess from
# $PM. Guessing the package manager as a proxy for "does this distro carry it"
# was wrong (it cost a multi-minute cargo build of tree-sitter on Fedora, which
# ships tree-sitter-cli); trying the distro first and falling back is correct.

HERE_PROVIDERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pkg.sh
source "$HERE_PROVIDERS/pkg.sh"

# provider_install <provider-spec> <command> <package>
#
# provider-spec may be a single provider or a `||` chain. Returns 0 as soon as
# one provider succeeds.
provider_install() {
  local spec="$1" cmd="$2" pkg="$3"

  # Already present? Nothing to do — this is what makes running several
  # sections in a row cheap when they share tools (rg and fd are in both
  # [bash] and [nvim]).
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  local IFS='|'
  read -ra chain <<<"${spec//||/|}"
  unset IFS

  local p
  for p in "${chain[@]}"; do
    [[ -z "$p" ]] && continue
    if _provider_try "$p" "$cmd" "$pkg"; then
      return 0
    fi
    echo "  ↩︎  $p could not provide $cmd — trying next"
  done

  echo "  ⚠️  no provider could install $cmd (tried: $spec)"
  return 1
}

_provider_try() {
  local provider="$1" cmd="$2" pkg="$3"

  case "$provider" in
    pkg)   pkg_install   "$cmd" ;;
    npm)   npm_install   "$cmd" "$pkg" ;;
    uv)    uv_install    "$cmd" "$pkg" ;;
    cargo) cargo_install "$cmd" "$pkg" ;;
    mise)  mise_install  "$cmd" "$pkg" ;;
    manual)
      # Not installable from here — it means "an official installer or a
      # hand-extracted build is an acceptable source for this tool". Declaring
      # it keeps `make status` honest: zoxide from its curl installer and
      # wezterm extracted into ~/.local are correct states, not drift. The
      # actual install lives in the section's deps.sh escape hatch.
      echo "  ↷  $cmd is provided manually — see the section's deps.sh"
      return 1
      ;;
    *)
      echo "  ❌ unknown provider '$provider' for $cmd (check deps.conf)"
      return 1
      ;;
  esac

  # Trust the tool, not the installer's exit code: some package managers
  # report success while installing a differently-named binary.
  command -v "$cmd" >/dev/null 2>&1
}

# Which providers a section needs — used to warn early rather than failing
# halfway through an install.
provider_prereqs() {
  local spec p seen=""
  for spec in "$@"; do
    local IFS='|'
    read -ra chain <<<"${spec//||/|}"
    unset IFS
    for p in "${chain[@]}"; do
      [[ -z "$p" ]] && continue
      [[ "$seen" == *" $p "* ]] && continue
      seen="$seen $p "
    done
  done
  echo "$seen"
}
