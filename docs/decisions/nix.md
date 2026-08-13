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

**Versions are only half-pinned.** `bun.lock` genuinely pins the JS servers. mise does
not: `lib/pkg.sh` calls `mise use -g "$tool@latest"`, and the resolved versions land in
`~/.config/mise/config.toml` — untracked, machine-local, outside the repo. Two machines
provisioned a month apart get different versions with nothing in the repo recording it.

The fix is `mise lock`, which records resolved versions, checksums and per-platform URLs,
following the `bun.lock` / `yarn.lock` precedent already set on the nvim side: a
generated `mise.toml` derived from `deps.conf`, a committed `mise.lock`, and a CI check
asserting the two agree. Until that lands, treat "pinned" as a claim about `bun.lock`
only.

With the lockfile in place, the remaining delta to Nix is sandboxing and a true
dependency closure — real, but smaller than the cost of switching.

## The hedge

Dependencies are *data*, so adopting Nix means writing a `nix` provider in
`lib/providers.sh`, not a rewrite. That is the one line of this document that affects how
you write code today; it is repeated in `CLAUDE.md` for that reason.
