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
