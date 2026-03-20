#!/usr/bin/env bash
set -euo pipefail

# ─── Bootstrap: install all external tools for roest-nvim ─────────────────────
#
# Installs:
#   1. Core tools (from reqs.lua) — git, make, rg, fd, stylua, prettierd, prettier
#   2. Formatters & linters — ruff, eslint_d
#   3. Productivity tools — zoxide, fzf, bat, eza (for ~/.bash_roest_productivity)
#
# Run:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh

install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  echo "  ➡️  Installing $tool..."

  if command -v brew >/dev/null 2>&1; then
    brew install "$tool" 2>/dev/null || echo "  ⚠️  brew install $tool failed"
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install -y "$tool" 2>/dev/null || echo "  ⚠️  apt install $tool failed"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$tool" 2>/dev/null || echo "  ⚠️  dnf install $tool failed"
  else
    echo "  ❌ No supported package manager. Install $tool manually."
    return 1
  fi
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
    || echo "  ⚠️  pip install $tool failed (install pip or use brew)"
}

npm_install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  echo "  ➡️  Installing $tool via npm..."
  npm install -g "$tool" 2>/dev/null \
    || echo "  ⚠️  npm install $tool failed (install node/npm first)"
}

echo ""
echo "🔧 roest-nvim bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── 1. Core tools (from reqs.lua) ────────────────────────────────────────────

echo ""
echo "📦 Core tools (required by nvim config):"

if [[ -f "lua/external/reqs.lua" ]]; then
  tools=$(grep -oP "'\K[^']+" lua/external/reqs.lua)
  for tool in $tools; do
    install "$tool"
  done
else
  echo "  ⚠️  lua/external/reqs.lua not found — skipping core tools"
fi

# ─── 2. Formatters & linters ──────────────────────────────────────────────────

echo ""
echo "🎨 Formatters & linters (used by conform.nvim + nvim-lint):"

pip_install "ruff"
npm_install "eslint_d"

# ─── 3. Productivity tools (optional, for ~/.bash_roest_productivity) ─────────

echo ""
echo "⚡ Productivity tools (optional, for bash_roest_productivity):"

install "zoxide"
install "fzf"

if ! command -v bat >/dev/null 2>&1 && ! command -v batcat >/dev/null 2>&1; then
  install "bat"
else
  echo "  ✅ bat"
fi

install "eza"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Done! Next steps:"
echo ""
echo "  1. Open nvim — plugins install automatically"
echo "  2. Run :checkhealth to verify"
echo "  3. Run :helptags ~/.config/nvim/doc"
echo ""
