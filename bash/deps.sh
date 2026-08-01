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

# macOS ships bash 3.2; this config wants 5.x. Not a manifest line because it
# applies only to brew.
if [ "$PM" = "brew" ]; then
  pkg_install "bash"
fi

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
