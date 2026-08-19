#!/usr/bin/env bash
# ─── Shared package-install helpers ──────────────────────────────────────────
#
# Sourced by lib/run.sh and by each section's optional deps.sh (bash/, nvim/,
# wezterm/) so there is exactly ONE implementation of "install a tool" here.
#
# Idempotency is structural, not incidental: every *_install helper short-circuits
# on `command -v`. That is what makes it safe for `make install` to run several
# sections in a row when they share tools (fd and rg are wanted by both bash and
# nvim) — the second one prints ✅ and does no work.
#
# The exception is mise_install_forced, which skips that short-circuit on
# purpose: `command -v` answers "does this exist", which is the wrong question
# when a distro ships a version too old to run. See nvim/deps.sh.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg.sh"
#   pkg_detect          # sets $PM
#   pkg_install rg

# ─── Detect the host ─────────────────────────────────────────────────────────

# WSL is Linux by every test this repo already makes — uname says Linux, apt is
# real, $PM is apt — and yet some things belong to the Windows host rather than
# the guest. The terminal is the whole of it today: wezterm.exe draws the pixels
# out there, so a wezterm installed in here is a GUI nothing launches and fonts
# nothing renders.
#
# /proc/version rather than $WSL_DISTRO_NAME: the env var is set by the WSL
# init for interactive shells, and `make` runs neither login nor interactive,
# so it is frequently absent exactly when this is asked. The kernel string is
# always there.
is_wsl() {
  grep -qiE "microsoft|wsl" /proc/version 2>/dev/null
}

# Is this tool ours to install on THIS host?
#
# One case, and it earns naming a tool outside deps.conf the way the bat/batcat
# and fd/fdfind fallbacks in run_check already do. The alternative was a section
# applicability line in the manifest, which is the `platform` mechanism that was
# deliberately deleted — a whole line type, a parser change and a CI rule to
# describe a single tool.
#
# wezterm is the case: under WSL the terminal is wezterm.exe on the Windows
# host. `make install` in the guest cannot install it, and `make check` calling
# it MISSING is advice that can never be satisfied — it tells you to run
# `make install wezterm`, which is precisely what just failed to help.
#
# Note this covers the TOOL only. The [wezterm] links are still made in the
# guest: wezterm.lua declares the `mux` unix domain on a guest socket path, so
# a wezterm-mux-server running in WSL reads it.
tool_applies_here() {
  case "$1" in
    wezterm) ! is_wsl ;;
    *)       true ;;
  esac
}

# ─── Detect package manager ──────────────────────────────────────────────────

# On macOS, brew IS the system package manager. On Linux it is a supplementary
# one that may or may not be installed, and preferring it over the distro's was
# wrong: a RHEL 9 box with linuxbrew present got PM=brew, so `pkg` meant "ask
# Homebrew" for everything. Two installs failed there that dnf would have done —
# `brew install mise` (fell back to mise.run) and `brew install pngpaste`, which
# has no Linux bottle at all — and the dnf-only clang/bindgen branch in
# nvim/deps.sh went dead because it tests `$PM = dnf`.
#
# So: distro first on Linux, brew as the fallback for machines that have no
# apt/dnf but do have linuxbrew.
PM=""
pkg_detect() {
  if [ "$(uname -s)" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 && PM="brew"
  elif command -v apt >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v brew >/dev/null 2>&1; then
    PM="brew"
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
    # stderr stays open on the sudo paths. It carries two things worth seeing:
    # the package manager's reason for failing — otherwise the ⚠️ below is the
    # only trace, and it says "failed" without saying why — and sudo's PAM
    # conversation. pam_fprintd writes "Place your finger on the fingerprint
    # reader" there while the password prompt goes to /dev/tty, so suppressing
    # stderr turns fingerprint auth into a silent 30-second stall.
    apt)
      local pkg
      pkg=$(apt_pkg_name "$cmd")
      # Ask before escalating. `sudo apt install wezterm` on a distro that has
      # no such package still prompts for a password first and only THEN says
      # "Unable to locate package" — so the cost of a package apt was never
      # going to provide is an interactive stop, in the middle of an install
      # that had been running unattended. apt-cache reads the local lists, so
      # this costs nothing and needs no network.
      #
      # apt only. dnf's equivalent either hits the network or trusts a cache
      # that may be empty, and a false "no such package" there would silently
      # skip a package that does exist — worse than the prompt this avoids.
      if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "  ↩︎  apt has no package '$pkg'"
        return 1
      fi
      sudo apt install -y "$pkg" || { echo "  ⚠️  apt install $pkg failed"; return 1; }
      ;;
    dnf)
      local pkg
      pkg=$(dnf_pkg_name "$cmd")
      sudo dnf install -y "$pkg" || { echo "  ⚠️  dnf install $pkg failed"; return 1; }
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
# pkg_upgrade <package>
#
# Upgrade a distro package that is installed but too old. Deliberately narrow:
# there is no general "keep everything current" here, because that is the
# system's job, not this repo's. It exists so a version floor can be satisfied
# by the package already on the machine instead of installing a second copy
# alongside it — Fedora 44 shipping neovim 0.12.4 while a stale box sat on
# 0.11.6 is the case that motivated it.
#
# Returns non-zero if the upgrade didn't happen or didn't help; the caller is
# expected to fall back.
pkg_upgrade() {
  local pkg="$1"

  case "$PM" in
    brew) brew upgrade "$pkg" >/dev/null 2>&1 || return 1 ;;
    apt)  sudo apt install -y --only-upgrade "$pkg" >/dev/null 2>&1 || return 1 ;;
    dnf)  sudo dnf upgrade -y "$pkg" >/dev/null 2>&1 || return 1 ;;
    *)    return 1 ;;
  esac
}

mise_install() {
  local cmd="$1"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  mise_install_forced "$@"
}

# mise_install_forced <cmd> [tool]
#
# mise_install without the `command -v` short-circuit, for when the command is
# present but not usable. `command -v` answers "does this exist", which is the
# right question almost everywhere and the wrong one when a distro ships a
# version too old to run the config — Ubuntu 24.04's neovim 0.9.5 against a
# config that needs 0.10+. The caller decides it's unusable; this just installs
# over it. See the version floor in nvim/deps.sh for the only current use.
# The pinned "name@version" for a tool, from the repo's generated mise.toml.
# Empty if the tool isn't pinned there.
#
# Two names are tried because mise's registry name matches neither field of a
# deps.conf tool line consistently: `nvim neovim` is `neovim` to mise (the
# package field), while `tree-sitter tree-sitter-cli` is `tree-sitter` (the
# command) — `tree-sitter-cli` is cargo's and dnf's name and mise has no such
# entry, so the old `mise use -g "${pkg:-$cmd}@latest"` could never have
# installed it. tools/gen-mise.sh resolves the name against the registry and
# writes the winner here, so this just has to find it.
_mise_pin() {
  local cmd="$1" pkg="${2:-}" root candidate version
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -f "$root/mise.toml" ]] || return 0
  for candidate in "${pkg:-$cmd}" "$cmd"; do
    [[ -z "$candidate" ]] && continue
    version="$(sed -n "s/^${candidate} = \"\(.*\)\"\$/\1/p" "$root/mise.toml" | head -1)"
    [[ -n "$version" ]] && { echo "${candidate}@${version}"; return 0; }
  done
  return 0
}

mise_install_forced() {
  local cmd="$1" pkg="${2:-}" spec

  if ! command -v mise >/dev/null 2>&1; then
    echo "  ➡️  Installing mise..."
    pkg_install "mise" || curl -fsSL https://mise.run | sh
    export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  fi

  command -v mise >/dev/null 2>&1 || { echo "  ⚠️  mise unavailable — skipping ${pkg:-$cmd}"; return 1; }

  # Pinned wins. `@latest` is the fallback, not the default, and it announces
  # itself: an unpinned install is how two machines built a month apart ended
  # up with different software and nothing in the repo recording which.
  spec="$(_mise_pin "$cmd" "$pkg")"
  if [[ -z "$spec" ]]; then
    spec="${pkg:-$cmd}@latest"
    echo "  ⚠️  ${pkg:-$cmd} is not pinned in mise.toml — installing unpinned"
    echo "      (run 'make mise-lock' to pin it)"
  fi

  echo "  ➡️  Installing $spec via mise..."
  # -g so the tool is on PATH everywhere, not only inside this repo. The repo's
  # mise.toml is the source of the version; the global config is where it's
  # applied.
  mise use -g "$spec" 2>/dev/null || {
    echo "  ⚠️  mise use -g $spec failed"
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
