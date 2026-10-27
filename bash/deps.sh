#!/usr/bin/env bash
set -euo pipefail

# ─── [bash] platform fixups ──────────────────────────────────────────────────
#
# The tools themselves are declared in deps.conf. This file exists only for
# things that are genuinely conditional on the platform and can't be expressed
# as a manifest line without inventing a DSL for `if`.
#
# Run automatically after the [bash] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

# Debian/Ubuntu install these under different binary names than everyone else.
# The manifest asks for `fd` and `bat`; apt delivers `fdfind` and `batcat`.
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ensure_symlink "fdfind" "fd"
fi
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  ensure_symlink "batcat" "bat"
fi

# zoxide: Fedora packages it, base RHEL does not. The manifest declares `pkg`
# because that's right nearly everywhere; this catches the case where the
# package genuinely doesn't exist. Runs only if the providers already failed.
if ! command -v zoxide >/dev/null 2>&1; then
  echo "  ➡️  zoxide not packaged here — using the official installer..."
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi

# uv is NOT installed here, and the absence is deliberate. It moved to its own
# [uv] section, because this section may not depend on a curl-piped installer
# (see CONTRIBUTING.md) and uv can no longer come from `pkg` — the distro build
# has `uv self update` compiled out. `make install` sweeps [uv] too, so a normal
# machine is unaffected; a machine that opts out of [uv] loses exactly
# 2parquet/2feather/2pickle, which guard on `command -v uv` and say so.

# WSL: clip.exe, and every other .exe, stops running when a package upgrade
# restarts systemd-binfmt. See ensure_wsl_interop in lib/pkg.sh. Never fatal —
# a guest without sudo still gets the rest of this file.
ensure_wsl_interop || true

# ── fzf: no version floor any more ───────────────────────────────────────────
#
# There was one, 0.65, and this is where it was enforced over an
# already-installed distro fzf. It existed for `github`, which needed
# `--listen` and the start/focus events for live previews and `--style` /
# `--footer` for the chrome -- none of which apt's 0.29 (Ubuntu 22.04) or 0.44
# (24.04) had.
#
# `github` is a Rust binary now (tui/github) and uses no fzf. The menu and
# list wrappers in bash_productivity went with it, having lost every caller.
# What is left is fzf's OWN shell integration -- Ctrl+R, Ctrl+T, Alt+C, via
# `eval "$(fzf --bash)"` -- which already falls back to the packaged
# completion script on an fzf too old to know `--bash`. So nothing here has a
# version requirement to state, and deps.conf's fzf line went back to
# `pkg||mise`: one binary from the distro, mise only where pkg cannot serve.
#
# Do not restore a floor without a caller that needs it. A floor cannot fail
# safe -- every version at or above it passes untested -- which is why
# `wezterm/MIN_VERSION` was deleted, and a floor with no caller at all is
# worse: it forces a second fzf onto machines whose own was fine.
