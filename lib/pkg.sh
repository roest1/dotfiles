#!/usr/bin/env bash
# ─── Shared package-install helpers ──────────────────────────────────────────
#
# Sourced by every area installer (bash/deps.sh, nvim/deps.sh, dev/deps.sh)
# so there is exactly ONE implementation of "install a tool" in this repo.
#
# Idempotency is structural, not incidental: every *_install helper short-circuits
# on `command -v`. That is what makes it safe for `make all` to run several area
# installers in a row when they share tools (fd and rg are wanted by both bash
# and nvim) — the second one prints ✅ and does no work.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg.sh"
#   pkg_detect          # sets $PM
#   pkg_install rg

# ─── Detect package manager ──────────────────────────────────────────────────

PM=""
pkg_detect() {
  if command -v brew >/dev/null 2>&1; then
    PM="brew"
  elif command -v apt >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  fi
  export PM
}

# ─── Name mapping (command name -> package name, where they differ) ─────────

apt_pkg_name() {
  case "$1" in
    rg)          echo "ripgrep" ;;
    fd)          echo "fd-find" ;;
    node|nodejs) echo "nodejs" ;;
    nvim)        echo "neovim" ;;
    wl-paste)    echo "wl-clipboard" ;;
    *)           echo "$1" ;;
  esac
}

dnf_pkg_name() {
  case "$1" in
    rg)       echo "ripgrep" ;;
    fd)       echo "fd-find" ;;
    node)     echo "nodejs" ;;
    nvim)     echo "neovim" ;;
    wl-paste) echo "wl-clipboard" ;;
    *)        echo "$1" ;;
  esac
}

# ─── Installers ──────────────────────────────────────────────────────────────

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

# Create a symlink in ~/.local/bin if the target name isn't already available.
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

# Install a Python tool with uv. Usage: uv_install <command> [package]
#
# Replaces pip_install: uv is packaged by distros (no curl needed), installs
# tools into isolated environments, and is made by the same people as ruff.
uv_install() {
  local cmd="$1"
  local pkg="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  if ! command -v uv >/dev/null 2>&1; then
    echo "  ➡️  Installing uv..."
    pkg_install "uv" || {
      curl -LsSf https://astral.sh/uv/install.sh | sh
      ensure_local_bin_on_path
      export PATH="$HOME/.local/bin:$PATH"
    }
  fi

  command -v uv >/dev/null 2>&1 || { echo "  ⚠️  uv unavailable — skipping $pkg"; return 1; }

  echo "  ➡️  Installing $pkg via uv..."
  uv tool install "$pkg" 2>/dev/null || { echo "  ⚠️  uv tool install $pkg failed"; return 1; }
  # uv puts shims in ~/.local/bin
  ensure_local_bin_on_path
}

# Install a tool with mise. Usage: mise_install <command> [tool-name]
#
# For tools distros don't reliably carry (stylua, tree-sitter, bun). Gives
# pinned versions across machines and downloads binaries instead of compiling.
mise_install() {
  local cmd="$1"
  local tool="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  if ! command -v mise >/dev/null 2>&1; then
    echo "  ➡️  Installing mise..."
    pkg_install "mise" || curl -fsSL https://mise.run | sh
    export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  fi

  command -v mise >/dev/null 2>&1 || { echo "  ⚠️  mise unavailable — skipping $tool"; return 1; }

  echo "  ➡️  Installing $tool via mise..."
  mise use -g "$tool@latest" 2>/dev/null || {
    echo "  ⚠️  mise use -g $tool failed"
    return 1
  }
  export PATH="$HOME/.local/share/mise/shims:$PATH"
}

# Ensure ~/.local/bin is on PATH for this process (apt symlinks, uv/cargo bins).
ensure_local_bin_on_path() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
}
