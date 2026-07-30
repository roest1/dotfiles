#!/usr/bin/env bash
set -euo pipefail

# ─── bash area: shell CLI tools ──────────────────────────────────────────────
#
# Tools the bash config itself reaches for. This is the ONLY area a locked-down
# work machine needs — see `make bash`. Nothing here assumes an editor.
#
# fd and rg are also wanted by the nvim area; the helpers short-circuit on
# `command -v`, so whichever area runs second just prints ✅.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

echo ""
echo "🐚 bash — shell tools"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Platform: $(uname -s) (${PM:-no package manager found})"
echo ""

# macOS ships bash 3.2; this config wants 5.x
if [ "$PM" = "brew" ]; then
  pkg_install "bash"
fi

pkg_install "fzf"
pkg_install "gh"
pkg_install "jq"
pkg_install "rg"
pkg_install "fd"

# On apt, fd-find installs as 'fdfind'
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ensure_symlink "fdfind" "fd"
fi

# bat: on apt, installed as 'batcat'
if ! command -v bat >/dev/null 2>&1 && ! command -v batcat >/dev/null 2>&1; then
  pkg_install "bat"
else
  echo "  ✅ bat"
fi
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  ensure_symlink "batcat" "bat"
fi

# eza: in brew and newer apt repos, cargo fallback elsewhere
if [ "$PM" = "brew" ]; then
  pkg_install "eza"
else
  pkg_install "eza" || cargo_install "eza"
fi

# zoxide: not in base RHEL repos — official installer as fallback
if ! command -v zoxide >/dev/null 2>&1; then
  pkg_install "zoxide" || {
    echo "  ➡️  Installing zoxide via official installer..."
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  }
else
  echo "  ✅ zoxide"
fi

echo ""
echo "  Done. Verify with: make check-bash"
echo ""
