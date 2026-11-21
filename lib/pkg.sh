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

# ─── Does this tool apply on this host? ──────────────────────────────────────

# Is this tool ours to install on THIS host? Consulted by run_tools, run_check
# and status_tools, so the three agree.
#
# A dotnet global tool applies exactly where dotnet does. dotnet itself is a
# project toolchain this repo does not install, so on a box without it the C#
# server is n/a rather than MISSING -- roslyn.nvim cannot attach there either
# way, and MISSING would send `make install nvim` to fetch something it has no
# runtime for.
tool_applies_here() {
  case "$1" in
    roslyn-language-server) command -v dotnet >/dev/null 2>&1 ;;
    *) true ;;
  esac
}

# Why tool_applies_here said no, for the two status lines that print it.
tool_na_reason() {
  case "$1" in
    roslyn-language-server) echo "no dotnet on this machine" ;;
    *) echo "not applicable here" ;;
  esac
}

# ─── dnf: one setting, never the file ───────────────────────────────────────
#
# The only dnf option worth owning here. dnf4 and dnf5 both default to 3
# parallel downloads; past ~10 the link or the mirror is the limit rather than
# the count, and 20 is dnf's ceiling. One value for every machine, because there
# is nothing per-machine to tune: a slower link just saturates sooner.
#
# Set through dnf's own setter, which edits that one key in place and leaves the
# rest of dnf.conf alone. That matters on the work RHEL box, whose dnf.conf is
# not this repo's to rewrite. A re-run on a machine already at the value asks
# for no password: sudo is reached only when the value is wrong. Called from
# bash/deps.sh.
#
# The two dnfs spell it differently, and both are in the fleet: Fedora 44 is
# dnf5, while RHEL 9 and 10 stay on dnf4 (Red Hat does not build dnf5 for 10).
DNF_MAX_PARALLEL_DOWNLOADS=10

# Captured, then tested: no pipe. `dnf --version | head -1 | grep -q` under
# `set -o pipefail` (bash/deps.sh sets it) answers false whenever head closes
# the pipe before dnf has finished writing, because dnf then dies of SIGPIPE
# and the pipeline inherits its 141. That depends on timing. It passed in a
# local fedora:44 container and failed on the CI runner, which took the dnf4
# branch on Fedora 44 and reported `Unknown argument "--save"`.
dnf_is_dnf5() {
  local v
  v="$(dnf --version 2>/dev/null)" || return 1
  [[ "$v" == dnf5* ]]
}

# The EFFECTIVE value -- what dnf will use after every config file and drop-in
# is read -- not a grep of dnf.conf, which a dnf5 drop-in can override.
dnf_max_parallel_downloads() {
  local dump
  if dnf_is_dnf5; then
    dump="$(dnf --dump-main-config 2>/dev/null)"
  else
    dump="$(dnf config-manager --dump 2>/dev/null)"
  fi
  printf '%s\n' "$dump" | sed -n '/^max_parallel_downloads *= */{s///p;q}'
}

ensure_dnf_parallel() {
  command -v dnf >/dev/null 2>&1 || { echo "  ↷  no dnf on this machine"; return 0; }
  local want="$DNF_MAX_PARALLEL_DOWNLOADS" have
  have="$(dnf_max_parallel_downloads)"
  if [[ "$have" == "$want" ]]; then
    echo "  ✅ dnf max_parallel_downloads=$want"
    return 0
  fi
  echo "  ➡️  dnf max_parallel_downloads ${have:-?} -> $want..."
  if dnf_is_dnf5; then
    sudo dnf config-manager setopt "max_parallel_downloads=$want"
  else
    sudo dnf config-manager --save --setopt="max_parallel_downloads=$want" >/dev/null
  fi || { echo "  ⚠️  could not set max_parallel_downloads"; return 1; }
  [[ "$(dnf_max_parallel_downloads)" == "$want" ]] \
    || { echo "  ⚠️  set, but dnf still reports $(dnf_max_parallel_downloads)"; return 1; }
  echo "  ✅ dnf max_parallel_downloads=$want"
}

# ─── Detect package manager ──────────────────────────────────────────────────

# dnf is the only system package manager: the fleet is Fedora and RHEL. apt
# went with WSL and Ubuntu on 2026-11-21, and a linuxbrew that happens to be
# installed is never `pkg` -- it was preferred over the distro once, on a RHEL
# 9 box, and two installs failed that dnf would have done. lib/status.sh still
# names a linuxbrew copy when it finds one, as provider `brew`.
#
# $PM stays a variable rather than becoming a constant so an unsupported host
# (no dnf at all) says so at install time instead of failing on each tool.
PM=""
pkg_detect() {
  if command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  fi
  export PM
}

# ─── Name mapping (command name -> package name, where they differ) ─────────

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
    # stderr stays open on the sudo paths. It carries two things worth seeing:
    # the package manager's reason for failing — otherwise the ⚠️ below is the
    # only trace, and it says "failed" without saying why — and sudo's PAM
    # conversation. pam_fprintd writes "Place your finger on the fingerprint
    # reader" there while the password prompt goes to /dev/tty, so suppressing
    # stderr turns fingerprint auth into a silent 30-second stall.
    dnf)
      local pkg
      pkg=$(dnf_pkg_name "$cmd")
      sudo dnf install -y "$pkg" || { echo "  ⚠️  dnf install $pkg failed"; return 1; }
      ;;
    *)
      echo "  ❌ No dnf on this machine (Fedora/RHEL only). Install $cmd manually."
      return 1
      ;;
  esac
}

# Install a cargo crate. Usage: cargo_install <command_name> [crate_name]
# Make sure `cargo` exists, installing rustup if it does not. Usage: ensure_cargo
#
# Lifted out of cargo_install because a second caller appeared: tui/deps.sh
# builds this repo's own crates with `cargo install --path`, which the manifest's
# cargo provider cannot express, and it should not get to hold its own opinion
# about what a missing cargo means. One implementation, two callers.
#
# rustup rather than the distro package, which is the opposite of this repo's
# usual preference and the same exception [nvim] makes for the same reason: the
# workspace declares a rust-version floor, distro rust lags it, and a toolchain
# too old to build the tree fails at the END of a long install rather than at
# the start. rustup also keeps itself current, which `dnf install rust` cannot.
#
# The curl-piped installer is not a new precedent here: uv and mise both
# arrive this way when a package manager cannot serve them.
ensure_cargo() {
  command -v cargo >/dev/null 2>&1 && return 0

  echo "  ⚠️  cargo not found — installing rustup..."
  curl https://sh.rustup.rs -sSf | sh -s -- -y || {
    echo "  ❌ rustup install failed. Install it manually: https://rustup.rs"
    return 1
  }
  # The installer only edits shell rc files, which this shell has already read.
  # Without this the very next `command -v cargo` still fails.
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"

  # Both checks are load-bearing, and it is not belt-and-braces. `curl | sh`
  # exits with SH's status, so a curl that 404s still reports success unless
  # the caller set pipefail — and whether it did is the caller's business, not
  # this function's. Asking whether cargo is now runnable is the only test that
  # does not depend on that.
  command -v cargo >/dev/null 2>&1 || {
    echo "  ❌ cargo still not on PATH. Install rustup manually: https://rustup.rs"
    return 1
  }
}

# cargo can download and compile without a C toolchain, and then fail at the
# LINK step, minutes in, with a wall of build-script output. Every crate needs a
# linker, so ask before starting rather than after. A minimal RHEL 9 has none:
# that is how eza failed in CI's AlmaLinux row.
cargo_can_link() {
  command -v cc >/dev/null 2>&1 && return 0
  echo "  ❌ cargo needs a C linker and there is no \`cc\`. Install one:"
  echo "       sudo dnf install gcc"
  return 1
}

cargo_install() {
  local cmd="$1"
  local crate="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  ensure_cargo || return 1
  cargo_can_link || return 1

  echo "  ➡️  Installing $crate via cargo..."
  cargo install "$crate" 2>/dev/null \
    || echo "  ⚠️  cargo install $crate failed"
}

# Make sure `uv` exists, installing it from Astral's installer if it does not.
# Usage: ensure_uv
#
# The sibling of ensure_cargo, lifted out for the same reason: a second caller
# appeared. uv/deps.sh installs uv as a tool in its own right, uv_install wants
# it as a means to an end, and neither should hold its own opinion about where
# uv comes from. One implementation, two callers.
#
# THE ORDER HERE IS THE POINT, and it is the reverse of this file's habit. The
# official installer goes first and `pkg` is the fallback, because the distro
# package is not the same artefact: it has `uv self update` compiled out, so it
# can only ever be as current as the distro's next package bump. uv ships
# weekly. Fedora 44 shipped 0.11.32 against an upstream 0.12.9, and no amount
# of asking uv to update itself could close that. See [uv] in deps.conf.
#
# `pkg` stays as the fallback rather than being deleted, and that is not
# hedging: a machine that cannot reach astral.sh is better off with a stale uv
# than with none, and it is the only route left on a box with no network but a
# populated package cache. Nothing else in this repo needs uv to be current;
# the reason to prefer the installer is that the tool can then fix itself.
#
# Short-circuits on `command -v`, which means it will NOT install over a distro
# uv that is already present. That is deliberate — two copies on PATH is the
# problem in docs/decisions/tool-duplication.md, and installing a second one to
# fix the first makes it worse. uv/deps.sh reports that state instead.
ensure_uv() {
  command -v uv >/dev/null 2>&1 && return 0

  echo "  ➡️  Installing uv (official installer)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh || true
  ensure_local_bin_on_path

  # Asking whether uv is now runnable, rather than trusting the pipeline's exit
  # status — `curl | sh` exits with sh's status, so a curl that 404s still
  # reports success unless the caller set pipefail, and whether it did is not
  # this function's business. Same reasoning as ensure_cargo.
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi

  echo "  ↩︎  astral.sh unreachable — falling back to the distro package"
  echo "      (that build cannot 'uv self update'; re-run this once you have"
  echo "       a network to get the self-updatable one)"
  pkg_install "uv" || return 1
  command -v uv >/dev/null 2>&1
}

# Install a Python tool with uv. Usage: uv_install <command> [package]
#
# uv installs tools into isolated environments and is made
# by the same people as ruff. Where uv itself comes from is ensure_uv's call.
uv_install() {
  local cmd="$1"
  local pkg="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ✅ $cmd"
    return 0
  fi

  ensure_uv || { echo "  ⚠️  uv unavailable — skipping $pkg"; return 1; }

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
    dnf) sudo dnf upgrade -y "$pkg" >/dev/null 2>&1 || return 1 ;;
    *)   return 1 ;;
  esac
}

mise_install() {
  local cmd="$1" pkg="${2:-}" drift

  if command -v "$cmd" >/dev/null 2>&1; then
    # Present is not the same as current. When mise manages this tool here,
    # the version it runs comes from the GLOBAL config, which nothing but this
    # function writes. So a pin bumped in mise.toml would never reach a
    # machine that already had the tool, and "pull, make install" would leave
    # it on the old version while reporting ✅. That was the state until
    # 2026-11-09. See mise_global_drift.
    drift="$(mise_global_drift "$cmd" "$pkg")"
    if [[ -z "$drift" ]]; then
      echo "  ✅ $cmd"
      return 0
    fi
    echo "  ⬆️  $cmd: $drift"
  fi

  mise_install_forced "$@"
}

# The pinned "key@version" for a tool, from the repo's generated mise.toml.
# Empty if the tool isn't pinned there.
#
# Two names are tried because mise's registry name matches neither field of a
# deps.conf tool line consistently: `nvim neovim` is `neovim` to mise (the
# package field), while `tree-sitter tree-sitter-cli` is `tree-sitter` (the
# command) — `tree-sitter-cli` is cargo's and dnf's name and mise has no such
# entry, so the old `mise use -g "${pkg:-$cmd}@latest"` could never have
# installed it. tools/gen-mise.sh resolves the name against the registry and
# writes the winner here, so this just has to find it.
#
# The key may be backend-qualified ("aqua:neovim"), which is how
# gen-mise.sh picks a checksummed backend over a registry default that records
# none. The whole key is the spec: `mise use -g aqua:neovim@0.12.4`.
_mise_pin() {
  local cmd="$1" pkg="${2:-}" root key version
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -f "$root/mise.toml" ]] || return 0
  IFS=$'\t' read -r key version < <(_mise_toml_entries "$root/mise.toml" "$cmd" "$pkg")
  [[ -n "${key:-}" && -n "${version:-}" ]] && echo "${key}@${version}"
  return 0
}

# _mise_toml_entries <file> <cmd> [pkg]
#
# "key<TAB>value" for every [tools] entry in a mise config that names this
# tool, under either name, bare ("neovim") or backend-qualified
# ("aqua:neovim", or aqua's long form "aqua:neovim/neovim", matched on the
# name after the backend and any owner/). A value that is
# not a plain string (a table, an array) prints as "?", which never equals a
# pin and so reads as drift rather than being silently skipped.
_mise_toml_entries() {
  local file="$1" cmd="$2" pkg="${3:-}"
  [[ -f "$file" ]] || return 0
  awk -v a="${pkg:-$cmd}" -v b="$cmd" '
    /^[ \t]*\[/ { intools = ($0 ~ /^[ \t]*\[tools\][ \t]*$/); next }
    !intools || $0 !~ /=/ || $0 ~ /^[ \t]*#/ { next }
    {
      key = $0; sub(/[ \t]*=.*/, "", key); gsub(/^[ \t]+|"/, "", key)
      val = $0; sub(/^[^=]*=[ \t]*/, "", val); sub(/[ \t]+(#.*)?$/, "", val)
      if (val ~ /^"[^"]*"$/) gsub(/"/, "", val); else val = "?"
      name = key; sub(/^[^:]*:/, "", name); sub(/^.*\//, "", name)
      if (key == a || key == b || (key ~ /:/ && (name == a || name == b)))
        print key "\t" val
    }' "$file"
}

# The config `mise use -g` writes, resolved the way mise resolves it.
_mise_global_config() {
  echo "${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
}

# mise_global_drift <cmd> [pkg]
#
# Empty when there is nothing to converge, otherwise a one-line reason. There
# is nothing to converge when the global config does not list the tool (mise
# does not manage it on this machine: the distro or another provider does, and
# tier 1 of docs/decisions/toolchain-policy.md says leave that alone), or when
# mise.toml pins no version for it.
#
# Drift is any global entry that is not exactly the pin, key and value: an old
# "latest" from before pins existed, a version the repo has since bumped, or a
# bare "neovim" left behind after the pin moved to "aqua:neovim". An
# exact entry whose version is not on disk is drift too, the stale-shim case
# `make status` calls mise-stale.
mise_global_drift() {
  local cmd="$1" pkg="${2:-}" spec key val n=0 other=""
  spec="$(_mise_pin "$cmd" "$pkg")"
  [[ -n "$spec" ]] || return 0
  command -v mise >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r key val; do
    [[ -z "$key" ]] && continue
    n=$((n + 1))
    [[ "$key@$val" == "$spec" ]] || other="${other:+$other, }$key=$val"
  done < <(_mise_toml_entries "$(_mise_global_config)" "$cmd" "$pkg")
  [[ $n -eq 0 ]] && return 0
  if [[ -n "$other" ]]; then
    echo "global mise has $other, repo pins $spec"
  elif ! mise where "$spec" >/dev/null 2>&1; then
    echo "pinned $spec is not installed"
  fi
}

# mise_install_forced <cmd> [tool]
#
# mise_install without the `command -v` short-circuit, for when the command is
# present but not usable. `command -v` answers "does this exist", which is the
# right question almost everywhere and the wrong one when a distro ships a
# version too old to run the config — RHEL 9 EPEL's neovim 0.8.0 against a
# config that needs 0.12. The caller decides it's unusable; this just installs
# over it. Two callers: the version floor in nvim/deps.sh, and mise_install
# itself when mise_global_drift says the global config is not the pin.
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
  # stderr is kept, and printed only when mise fails. The old `2>/dev/null`
  # here cost a full investigation (issue #12): the nvim-floor job went red
  # with "mise use -g neovim@... failed" and nothing else, when mise had said
  # exactly what was wrong -- GitHub's API returning 429 to an anonymous
  # runner. Silence on success is still right; mise's progress output is noise
  # in `make install`. Silence on failure is what hid the cause.
  #
  # Run from the repo root, so mise reads the repo's mise.lock and refuses a
  # download whose sha256 does not match it. `-g` only says where the version
  # is recorded. Verified 2026-11-09 with a tampered hash: from the repo root,
  # `mise use -g` fails "Actual: sha256:...". make already runs here, which
  # is why this held before, but a caller elsewhere would install unchecked.
  local err root key _val
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if ! err="$(cd "$root" && mise use -g "$spec" 2>&1 >/dev/null)"; then
    echo "  ⚠️  mise use -g $spec failed"
    [ -n "$err" ] && printf '%s\n' "$err" | sed 's/^/      /'
    return 1
  fi
  # Retire any other global entry for the same tool, AFTER the new one is in,
  # so a failed install never leaves the machine with neither. Two entries
  # would both claim the same shim and leave which one runs to mise.
  while IFS=$'\t' read -r key _val; do
    [[ -z "$key" || "$key" == "${spec%@*}" ]] && continue
    (cd "$root" && mise unuse -g "$key" >/dev/null 2>&1) \
      || echo "  ⚠️  could not remove the old global entry '$key' (mise unuse -g $key)"
  done < <(_mise_toml_entries "$(_mise_global_config)" "$cmd" "$pkg")
  export PATH="$HOME/.local/share/mise/shims:$PATH"
}

# Ensure ~/.local/bin is on PATH for this process (uv/cargo bins).
ensure_local_bin_on_path() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi
}
