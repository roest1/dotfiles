#!/usr/bin/env bash
set -euo pipefail

# ─── Bootstrap: install all external tools for roest-nvim ─────────────────────
#
# Cross-platform: works on macOS (brew) and Linux/WSL (apt, dnf).
#
# Installs:
#   1. Core tools (from reqs.lua) — git, make, rg, fd, stylua, prettierd, prettier
#   2. Formatters & linters — ruff, eslint_d
#   3. Productivity tools — zoxide, fzf, bat, eza
#
# Run:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh

# ─── Detect package manager ──────────────────────────────────────────────────

PM=""
if command -v brew >/dev/null 2>&1; then
  PM="brew"
elif command -v apt >/dev/null 2>&1; then
  PM="apt"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Maps command name -> package name for apt (where they differ from brew/dnf)
apt_pkg_name() {
  case "$1" in
    rg)  echo "ripgrep" ;;
    fd)  echo "fd-find" ;;
    *)   echo "$1" ;;
  esac
}

# Install a system package. Usage: pkg_install <command_name>
pkg_install() {
  local cmd="$1"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  echo "  ➡️  Installing $cmd..."

  case "$PM" in
    brew)
      brew install "$cmd" 2>/dev/null || { echo "  ⚠️  brew install $cmd failed"; return 1; }
      ;;
    apt)
      local pkg
      pkg=$(apt_pkg_name "$cmd")
      sudo apt install -y "$pkg" 2>/dev/null || { echo "  ⚠️  apt install $pkg failed"; return 1; }
      ;;
    dnf)
      sudo dnf install -y "$cmd" 2>/dev/null || { echo "  ⚠️  dnf install $cmd failed"; return 1; }
      ;;
    *)
      echo "  ❌ No supported package manager. Install $cmd manually."
      return 1
      ;;
  esac
}

# Create a symlink in ~/.local/bin if the target doesn't already exist.
# Used on apt where binaries have different names (fdfind -> fd, batcat -> bat).
ensure_symlink() {
  local src="$1" dest="$2"
  if command -v "$dest" >/dev/null 2>&1; then
    return 0
  fi
  local src_path
  src_path=$(command -v "$src" 2>/dev/null) || return 1
  mkdir -p "$HOME/.local/bin"
  ln -sf "$src_path" "$HOME/.local/bin/$dest"
  echo "  🔗 Symlinked $src -> $dest (~/.local/bin/$dest)"
}

npm_install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "  ⚠️  npm not found — install node/npm first, then: npm install -g $tool"
    return 1
  fi

  echo "  ➡️  Installing $tool via npm..."
  npm install -g "$tool" 2>/dev/null \
    || echo "  ⚠️  npm install -g $tool failed"
}

pip_install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  echo "  ➡️  Installing $tool via pip..."
  pip install "$tool" --break-system-packages 2>/dev/null \
    || pip3 install "$tool" --break-system-packages 2>/dev/null \
    || pip install "$tool" 2>/dev/null \
    || pip3 install "$tool" 2>/dev/null \
    || echo "  ⚠️  pip install $tool failed (install pip or use brew)"
}

cargo_install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "  ⚠️  cargo not found — install rustup (https://rustup.rs) then: cargo install $tool"
    return 1
  fi

  echo "  ➡️  Installing $tool via cargo..."
  cargo install "$tool" 2>/dev/null \
    || echo "  ⚠️  cargo install $tool failed"
}

echo ""
echo "🔧 roest-nvim bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Platform: $(uname -s) (${PM:-no package manager found})"

# ─── Ensure ~/.local/bin is on PATH ─────────────────────────────────────────
# Needed for apt symlinks (fdfind->fd, batcat->bat) and pip/cargo installs.

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  echo ""
  echo "  ℹ️  Added ~/.local/bin to PATH for this session."
  echo "     Add to your shell rc for persistence:"
  echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ─── 1. Core tools ──────────────────────────────────────────────────────────

echo ""
echo "📦 Core tools:"

pkg_install "git"
pkg_install "make"
pkg_install "unzip"
pkg_install "rg"
pkg_install "fd"

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

# prettier ecosystem: always via npm
npm_install "prettierd"
npm_install "prettier"

# ─── 2. Formatters & linters ────────────────────────────────────────────────

echo ""
echo "🎨 Formatters & linters:"

pip_install "ruff"
npm_install "eslint_d"

# ─── 3. Productivity tools (optional) ───────────────────────────────────────

echo ""
echo "⚡ Productivity tools (optional):"

pkg_install "zoxide"
pkg_install "fzf"

# bat: on apt, installed as 'batcat' — symlink to 'bat'
if ! command -v bat >/dev/null 2>&1 && ! command -v batcat >/dev/null 2>&1; then
  pkg_install "bat"
else
  echo "  ✅ bat"
fi
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  ensure_symlink "batcat" "bat"
fi

# eza: in brew and newer apt repos, cargo fallback
if [ "$PM" = "brew" ]; then
  pkg_install "eza"
else
  pkg_install "eza" || cargo_install "eza"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Done! Next steps:"
echo ""
echo "  1. Open nvim — plugins install automatically"
echo "  2. Run :checkhealth to verify"
echo "  3. Run :helptags ~/.config/nvim/doc"
echo ""
