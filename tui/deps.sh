#!/usr/bin/env bash
# ─── [tui] — build the Rust terminal UIs ─────────────────────────────────────
#
# `cargo install --path`, which the manifest's `cargo` provider cannot express:
# it installs by crate NAME from crates.io, and `font` is a name someone else
# owns there. Hence `manual` in deps.conf and the real install here.
#
# --locked so a fresh machine builds the tree Cargo.lock describes rather than
# whatever resolves today, the same argument bun.lock gets in [nvim].
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v cargo >/dev/null 2>&1; then
  echo "  ⚠️  cargo not found — skipping the TUIs. Install rustup: https://rustup.rs"
  return 0 2>/dev/null || exit 0
fi

# An array rather than a literal list: `github` and the make-it console are
# the next two, and this is the line they get added to.
crates=(font)
for crate in "${crates[@]}"; do
  if cargo install --locked --path "$HERE/$crate" >/dev/null 2>&1; then
    echo "  ✅ $crate"
  else
    echo "  ⚠️  cargo install --path $HERE/$crate failed"
  fi
done
