#!/usr/bin/env bash
set -euo pipefail

# ─── nvim area: editor toolchain ─────────────────────────────────────────────
#
# Cross-platform: works on macOS (brew), Ubuntu/WSL (apt), and RHEL (dnf).
#
# Layers:
#   0. Runtimes    — node, npm, python3, pip, cargo
#   1. Core tools  — git, make, unzip, nvim, rg, fd, stylua
#   2. Formatters  — prettierd, prettier, ruff, eslint_d, tree-sitter-cli
#   3. Clipboard   — pngpaste (macOS) / xclip + wl-clipboard (Linux) for :PasteImage
#
# Shell tools (fzf, bat, eza, zoxide, gh, jq) belong to the bash area — see
# ../bash/deps.sh. rg and fd appear in both; the helpers short-circuit on
# `command -v`, so running both areas installs them once.
#
# Run:  ./deps.sh        (or, from the repo root: make deps-nvim)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect

echo ""
echo "🔧 nvim — editor toolchain"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Platform: $(uname -s) (${PM:-no package manager found})"

# ─── Ensure ~/.local/bin is on PATH ─────────────────────────────────────────
# Needed for apt symlinks (fdfind->fd, batcat->bat) and pip/cargo installs.

ensure_local_bin_on_path

# ─── 0. Runtimes ──────────────────────────────────────────────────────────────

echo ""
echo "🧠 Runtimes (required):"

case "$PM" in
  brew)
    pkg_install "node"
    pkg_install "python3"
    ;;
  apt)
    pkg_install "node"
    pkg_install "npm"
    pkg_install "python3"
    pkg_install "python3-pip"
    ;;
  dnf)
    pkg_install "node"
    pkg_install "npm"
    pkg_install "python3"
    pkg_install "python3-pip"
    ;;
esac

setup_npm_prefix

# ─── 1. Core tools ──────────────────────────────────────────────────────────

echo ""
echo "📦 Core tools:"

pkg_install "git"
pkg_install "make"
pkg_install "unzip"
pkg_install "nvim"
pkg_install "rg"
pkg_install "fd"

# clang/libclang: needed by cargo's bindgen (used by tree-sitter-cli build)
if [ "$PM" = "dnf" ]; then
  pkg_install "clang"
  pkg_install "clang-devel"
fi

# On apt, fd-find installs as 'fdfind' — symlink to 'fd' so nvim config works
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ensure_symlink "fdfind" "fd"
fi

# stylua: available in brew, but not in apt/dnf — use cargo as fallback
if [ "$PM" = "brew" ]; then
  pkg_install "stylua"
else
  cargo_install "stylua"
fi


# ─── 2. Formatters & linters ────────────────────────────────────────────────

echo ""
echo "🎨 Formatters & linters:"

# prettier ecosystem: always via npm
npm_install "prettierd" "@fsouza/prettierd"
npm_install "prettier"
pip_install "ruff"
npm_install "eslint_d"

# tree-sitter-cli: npm binary requires glibc 2.35+ which RHEL 9 doesn't have.
# Use cargo on dnf systems to compile from source; npm elsewhere.
if [ "$PM" = "dnf" ]; then
  cargo_install "tree-sitter" "tree-sitter-cli"
else
  npm_install "tree-sitter" "tree-sitter-cli"
fi

# ─── 3. Clipboard image paste (:PasteImage) ─────────────────────────────────
# Lets `:PasteImage` drop a screenshot from the OS clipboard into a directory
# (e.g. while browsing in Oil). Backend depends on the platform:
#   • WSL2  → uses Windows PowerShell, nothing to install
#   • macOS → pngpaste (brew)
#   • Linux → xclip (X11) + wl-clipboard (Wayland); install both, harmless

echo ""
echo "🖼️  Clipboard image paste (optional):"

if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  echo "  ✅ WSL — uses Windows PowerShell, no install needed"
elif [ "$PM" = "brew" ]; then
  pkg_install "pngpaste"
elif [ -n "${PM}" ]; then
  pkg_install "xclip"
  pkg_install "wl-paste"
fi

# ─── 4. Verify ──────────────────────────────────────────────────────────────

echo ""
echo "🔍 Verifying critical tools:"

MISSING=0
FIXES=""

check_tool() {
  local tool="$1"
  local fix="$2"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool ($(command -v "$tool"))"
  else
    echo "  ❌ $tool MISSING"
    FIXES="${FIXES}  ${fix}\n"
    MISSING=$((MISSING + 1))
  fi
}

check_tool "git"          "pkg: sudo ${PM:-apt} install git"
check_tool "nvim"         "pkg: sudo ${PM:-apt} install neovim"
check_tool "rg"           "pkg: sudo ${PM:-apt} install ripgrep"
check_tool "fd"           "pkg: sudo ${PM:-apt} install fd-find"
check_tool "node"         "pkg: sudo ${PM:-apt} install nodejs"
check_tool "npm"          "pkg: sudo ${PM:-apt} install npm"
check_tool "python3"      "pkg: sudo ${PM:-apt} install python3"
check_tool "tree-sitter"  "run: npm install -g tree-sitter-cli"
check_tool "stylua"       "run: cargo install stylua"
check_tool "prettier"     "run: npm install -g prettier"
check_tool "prettierd"    "run: npm install -g @fsouza/prettierd"
check_tool "ruff"         "run: python3 -m pip install --user ruff"
check_tool "eslint_d"     "run: npm install -g eslint_d"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$MISSING" -gt 0 ]; then
  echo "⚠️  Done with $MISSING missing tool(s)."
  echo ""
  echo "To fix, run:"
  echo ""
  echo -e "$FIXES"
else
  echo "🎉 Done! All critical tools installed."
fi
echo ""
echo "  Next steps:"
echo "    1. Open nvim — plugins install automatically"
echo "    2. Run :checkhealth to verify"
echo "    3. Run :TSUpdate to compile parsers"
echo ""
