#!/usr/bin/env bash
# ─── [tui] — build the Rust terminal UIs ─────────────────────────────────────
#
# `cargo install --path`, which the manifest's `cargo` provider cannot express:
# it installs by crate NAME from crates.io, and `font` is a name someone else
# owns there. Hence `manual` in deps.conf and the real install here.
#
# ─── cargo is REQUIRED, and this section does not apologise for it ──────────
#
# There is no prebuilt route yet: these binaries are built from the tree, so a
# machine without a Rust toolchain cannot have them. The earlier version warned
# and returned 0, which meant `make install` finished green and left the picker
# missing — the silently-dead install [nvim] already learned from, where an
# absent bun produced six language servers that were never going to start.
#
# Not wanting Rust is a legitimate answer, and it now has a real place to live:
# leave `tui` out of ~/.config/dotfiles/sections and the section is never swept
# at all. That escape hatch is why this can be a hard requirement instead of a
# soft one — an opt-out that survives a pull is worth more than a skip that
# pretends the install worked.
#
# Failing here is loud but not fatal: lib/run.sh reports a failed hook and
# carries on with the other sections, the same as every other deps.sh.
#
# --locked so a fresh machine builds the tree Cargo.lock describes rather than
# whatever resolves today, the same argument bun.lock gets in [nvim].
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

if ! ensure_cargo; then
  echo "  ❌ [tui] needs cargo — these binaries are built from source."
  echo "     To opt this machine out for good:"
  echo "       make sections > ~/.config/dotfiles/sections"
  echo "     then comment out 'tui'. Other sections are unaffected."
  exit 1
fi

# An array rather than a literal list: `github` and the make-it console are
# the next two, and this is the line they get added to.
crates=(font)
failed=0
for crate in "${crates[@]}"; do
  if cargo install --locked --path "$HERE/$crate" >/dev/null 2>&1; then
    echo "  ✅ $crate"
  else
    echo "  ⚠️  cargo install --path $HERE/$crate failed"
    failed=1
  fi
done
exit "$failed"
