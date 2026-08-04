#!/usr/bin/env bash
set -euo pipefail

# ─── [nvim] platform fixups ──────────────────────────────────────────────────
#
# The editor toolchain is declared in deps.conf. This file exists only for
# things that are genuinely conditional on the platform and can't be expressed
# as a manifest line without inventing a DSL for `if`.
#
# Run automatically after the [nvim] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

# ── neovim version floor ─────────────────────────────────────────────────────
#
# This config needs 0.10+ — lua/external/lsp_servers.lua calls vim.fs.joinpath,
# added in 0.10. Ubuntu 24.04's apt ships 0.9.5, and `pkg` legitimately succeeds
# there, so provider_install's `command -v` short-circuit sees a working nvim and
# stops. The result was a config that installed fine and then failed at startup
# with "attempt to call field 'joinpath' (a nil value)", which reads as a broken
# config rather than as too old a neovim. CI hit exactly this.
#
# deps.conf cannot express "at least 0.10": the manifest carries providers, not
# version constraints, and adding a version column would be inventing the `if`
# DSL that file exists to avoid. So the floor is enforced here, after the
# section's tools have run — which is what deps.sh is for.
#
# deps.conf declares `pkg||mise` so a mise-provided nvim is not reported as drift
# by `make status`.

NVIM_MIN_MAJOR=0
NVIM_MIN_MINOR=10

# Prints the running nvim's version, or nothing if absent/unparseable.
nvim_version() {
  command -v nvim >/dev/null 2>&1 || return 0
  nvim --version 2>/dev/null | awk 'NR==1 { sub(/^v/, "", $2); print $2 }'
}

# True when $1 is below the floor. Deliberately not `sort -V`: macOS ships BSD
# sort, and only major/minor matter here anyway.
nvim_below_floor() {
  local v="$1" maj min rest
  [ -n "$v" ] || return 1
  maj="${v%%.*}"; rest="${v#*.}"; min="${rest%%.*}"
  maj="${maj//[!0-9]/}"; min="${min//[!0-9]/}"
  [ -n "$maj" ] || return 1
  [ -n "$min" ] || min=0
  if [ "$maj" -lt "$NVIM_MIN_MAJOR" ]; then return 0; fi
  if [ "$maj" -eq "$NVIM_MIN_MAJOR" ] && [ "$min" -lt "$NVIM_MIN_MINOR" ]; then return 0; fi
  return 1
}

echo ""
echo "  neovim (need >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR):"
_nvim_v="$(nvim_version)"
if [ -z "$_nvim_v" ]; then
  echo "  ⚠️  nvim not installed — the [nvim] tools should have provided it"
elif nvim_below_floor "$_nvim_v"; then
  echo "  ↩︎  found $_nvim_v, below the floor — installing a current one via mise"
  mise_install_forced nvim neovim || {
    echo "  ❌ could not upgrade nvim. This config will fail to start on $_nvim_v."
    echo "     Install neovim >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR by hand, or run:"
    echo "       mise use -g neovim@latest"
  }
else
  echo "  ✅ nvim $_nvim_v"
fi

# clang/libclang: needed by cargo's bindgen, which a from-source tree-sitter
# build pulls in. Only install it when we'd actually compile — i.e. when
# tree-sitter is still missing after the manifest's providers have run.
if [ "$PM" = "dnf" ] && ! command -v tree-sitter >/dev/null 2>&1; then
  pkg_install "clang"
  pkg_install "clang-devel"
fi

# apt names fd differently; nvim's config calls it `fd`.
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ensure_symlink "fdfind" "fd"
fi

# ── lemminx (XML language server) ────────────────────────────────────────────
#
# The one server with no package manager anywhere: not in dnf, apt, brew, the
# aqua registry, or npm. Mason installed it by pulling a zip from
# redhat-developer/vscode-xml's releases, so this does the same thing — which is
# why deps.conf declares it `manual`.
#
# Checksums are published alongside each asset and are verified here. Downloading
# an executable over the network without checking it is not something this repo
# should do quietly.

install_lemminx() {
  command -v lemminx >/dev/null 2>&1 && { echo "  ✅ lemminx"; return 0; }

  local os arch asset
  case "$(uname -s)" in
    Darwin) os="osx" ;;
    Linux)  os="linux" ;;
    *) echo "  ⚠️  lemminx: unsupported OS $(uname -s) — skipping"; return 0 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    arm64|aarch64) arch="aarch_64" ;;
    *) echo "  ⚠️  lemminx: unsupported arch $(uname -m) — skipping"; return 0 ;;
  esac
  asset="lemminx-${os}-${arch}"

  command -v curl >/dev/null 2>&1 || { echo "  ⚠️  lemminx needs curl"; return 0; }
  command -v unzip >/dev/null 2>&1 || { echo "  ⚠️  lemminx needs unzip"; return 0; }

  local base tmp
  base="https://github.com/redhat-developer/vscode-xml/releases/latest/download"
  tmp="$(mktemp -d)"

  echo "  ➡️  Installing lemminx ($asset)..."
  if ! curl -fsSL "$base/${asset}.zip" -o "$tmp/l.zip" \
    || ! curl -fsSL "$base/${asset}.sha256" -o "$tmp/l.sha256"; then
    echo "  ⚠️  lemminx download failed — skipping"
    rm -rf "$tmp"; return 0
  fi

  unzip -qo "$tmp/l.zip" -d "$tmp" || { echo "  ⚠️  lemminx unzip failed"; rm -rf "$tmp"; return 0; }

  # The published .sha256 covers the EXTRACTED BINARY, not the zip — the
  # filename recorded inside it ("lemminx-linux-x86_64") is the giveaway.
  # That's the better thing to verify anyway: it checks the artifact actually
  # about to be executed, not the container it arrived in.
  local want got
  want="$(awk '{print $1}' "$tmp/l.sha256")"
  got="$(sha256sum "$tmp/$asset" 2>/dev/null | awk '{print $1}' \
         || shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
  if [ -z "$got" ] || [ "$want" != "$got" ]; then
    echo "  ❌ lemminx checksum mismatch — refusing to install"
    echo "     expected $want"
    echo "     got      ${got:-<could not hash>}"
    rm -rf "$tmp"; return 1
  fi

  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/$asset" "$HOME/.local/bin/lemminx" 2>/dev/null \
    || { echo "  ⚠️  lemminx: could not place binary"; rm -rf "$tmp"; return 0; }
  rm -rf "$tmp"
  echo "  🔗 lemminx -> ~/.local/bin/lemminx"
}

echo ""
echo "  lemminx (XML):"
install_lemminx

# ── Clipboard image paste (:PasteImage) ──────────────────────────────────────
# Lets `:PasteImage` drop a screenshot from the OS clipboard into a directory
# (e.g. while browsing in Oil). Backend depends on the platform:
#   • WSL2  → uses Windows PowerShell, nothing to install
#   • macOS → pngpaste (brew)
#   • Linux → xclip (X11) + wl-clipboard (Wayland); install both, harmless
#
# Genuinely a runtime probe (/proc/version), not something a manifest can state.

echo ""
echo "  clipboard image paste:"

if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  echo "  ✅ WSL — uses Windows PowerShell, no install needed"
elif [ "$PM" = "brew" ]; then
  pkg_install "pngpaste"
elif [ -n "${PM}" ]; then
  pkg_install "xclip"
  pkg_install "wl-paste"
fi
