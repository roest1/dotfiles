# Why not Nix

**Status:** deferred, revisit condition partially met.
**Applies to:** provider resolution, version pinning, provenance.

Nix + home-manager genuinely solves provider resolution, pinning and provenance, and
Fedora packages it with `nix-daemon` split out so single-user needs no daemon. It was
deferred — and one of the three original reasons has since expired, which is worth
recording rather than leaving a stale justification standing.

## No longer true

The strongest argument was that Mason kept the LSP layer imperative regardless, so Nix
would buy a reproducible `neovim`/`stylua`/`ripgrep` while six language servers stayed
mutable and still required node. **Mason is gone.** Every server is declared now —
`deps.conf` for the native ones, `nvim/lsp-servers/package.json` pinned in `bun.lock` for
the JS ones. That was the stated condition for revisiting, and it has been met.

## Still true

1. Steep learning curve on the repo that bootstraps every other machine. A half-understood
   Nix config fails on a fresh machine, which is the worst possible moment to find out.
2. `/nix` needs root — exactly the machine class `make link` exists for.

## Current honest assessment

The gap Nix would close is narrower than it was, but not as narrow as this document
previously claimed.

Provenance is answerable through `make status`, and nothing installs itself imperatively
at editor startup any more. Those hold.

**Versions are pinned now.** This section previously said they were not, and that a
generated `mise.toml`, a committed `mise.lock` and a CI check asserting the two agree
would be the fix. That landed. `mise.lock` records resolved versions, checksums and
per-platform URLs across 11 platforms, and `tools/gen-mise.sh --check` runs in CI. The
`mise use -g "$tool@latest"` path this warned about is gone: `lib/pkg.sh` reads the pin
and only falls back to `@latest` with a warning telling you to run `make mise-lock`.

Two caveats keep it from being a closed question.

`make install` does not enforce a pin it already has. `mise_install` short-circuits on
`command -v`, so a machine holding an older version of a pinned tool keeps it — the shim
is on PATH, the check passes, and the pin is never consulted. `make status` names this
case (`pinned X not installed`) and the remedy is `mise install`, but the install path
itself does not self-heal.

And pinning a version does not remove the versions it replaced, or the copies other
providers installed — see [`tool-duplication.md`](tool-duplication.md). `mise.lock` says
which version should win; PATH order decides which one does.

With the lockfile in place, the remaining delta to Nix is sandboxing and a true
dependency closure — real, but smaller than the cost of switching. Duplicate installs are
a genuine instance of that gap rather than a hypothetical one.

## The hedge

Dependencies are *data*, so adopting Nix means writing a `nix` provider in
`lib/providers.sh`, not a rewrite. That is the one line of this document that affects how
you write code today; it is repeated in `CLAUDE.md` for that reason.
