#!/usr/bin/env bash
set -euo pipefail

# ─── dev area: project runtimes ──────────────────────────────────────────────
#
# Runtimes that neither the shell config nor the editor needs — your *projects*
# need them. Deliberately excluded from `make bash` and `make nvim`, because a
# locked-down work machine may forbid curl-pipe installers even where it's fine
# to symlink a bashrc.
#
# bash/bashrc puts $BUN_INSTALL/bin on PATH behind a `[ -d ]` guard, so the
# shell config stays correct on machines where this area was never run.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

echo ""
echo "🧰 dev — project runtimes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# bun: no distro packages it — official installer only.
if command -v bun >/dev/null 2>&1; then
  echo "  ✅ bun ($(bun --version))"
else
  echo "  ➡️  Installing bun..."
  curl -fsSL https://bun.com/install | bash
fi

echo ""
echo "  Done. Verify with: make check-dev"
echo ""
