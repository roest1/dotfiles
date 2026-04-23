#!/usr/bin/env bash
set -euo pipefail

# ─── Bootstrap: install all external tools for roest-nvim ─────────────────────
#
# Cross-platform: works on macOS (brew), Ubuntu/WSL (apt), and RHEL (dnf).
#
# Layers:
#   0. Runtimes    — node, npm, python3, pip, cargo
#   1. Core tools  — git, make, unzip, rg, fd, stylua, prettierd, prettier
#   2. Formatters  — ruff, eslint_d, tree-sitter-cli
#   3. Productivity — zoxide, fzf, bat, eza
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
    rg)          echo "ripgrep" ;;
    fd)          echo "fd-find" ;;
    node|nodejs) echo "nodejs" ;;
    nvim)        echo "neovim" ;;
    *)           echo "$1" ;;
  esac
}

dnf_pkg_name() {
  case "$1" in
    rg)   echo "ripgrep" ;;
    node) echo "nodejs" ;;
    nvim) echo "neovim" ;;
    *)    echo "$1" ;;
  esac
}

# Install a system package. Usage: pkg_install <command_name> [package_override]
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
      local pkg
      pkg=$(dnf_pkg_name "$cmd")
      sudo dnf install -y "$pkg" 2>/dev/null || { echo "  ⚠️  dnf install $pkg failed"; return 1; }
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

# Ensure npm global prefix is user-writable (avoids EACCES on RHEL/Linux).
# Called once before any npm_install calls.
setup_npm_prefix() {
  command -v npm >/dev/null 2>&1 || return 0
  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null)"
  if [ ! -w "$npm_prefix" ] 2>/dev/null; then
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
  fi
  export PATH="$HOME/.npm-global/bin:$PATH"
}

# Install an npm package. Usage: npm_install <command_name> [package_name]
# If package_name is omitted, command_name is used as the package.
npm_install() {
  local cmd="$1"
  local pkg="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "  ⚠️  npm not found — install node/npm first, then: npm install -g $pkg"
    return 1
  fi

  echo "  ➡️  Installing $pkg via npm..."
  npm install -g "$pkg" 2>/dev/null \
    || { echo "  ⚠️  npm install -g $pkg failed"; return 1; }
}

pip_install() {
  local tool="$1"

  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✅ $tool"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ⚠️  python3 not found — skipping $tool"
    return 1
  fi

  echo "  ➡️  Installing $tool via pip (user)..."
  python3 -m pip install --user "$tool" 2>/dev/null \
    || python3 -m pip install "$tool" 2>/dev/null \
    || echo "  ⚠️  pip install $tool failed"
}

# Install a cargo crate. Usage: cargo_install <command_name> [crate_name]
# If crate_name is omitted, command_name is used as the crate.
cargo_install() {
  local cmd="$1"
  local crate="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "  ⚠️  cargo not found — installing rustup..."
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
    if ! command -v cargo >/dev/null 2>&1; then
      echo "  ❌ Failed to install cargo. Install rustup manually: https://rustup.rs"
      return 1
    fi
  fi

  echo "  ➡️  Installing $crate via cargo..."
  cargo install "$crate" 2>/dev/null \
    || echo "  ⚠️  cargo install $crate failed"
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
