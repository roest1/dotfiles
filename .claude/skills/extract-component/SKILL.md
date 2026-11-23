---
name: extract-component
description: Move a directory of this dotfiles repo into its own public repo and pin it back here as a git submodule at the same path, with history. Use when asked to extract, split out, break out, or spin off part of the dotfiles (a TUI, the nvim config, a font, a script) into its own repo, or to judge whether something should be.
---

# Extract a component

The rules are `docs/decisions/components.md`. Read it first; this file is only the order
of operations. Past extractions to copy from: `git show 71673f0` (ps1), `b1ee76c` (fonts),
`82fce00` (github-tui), `6ca35aa` (theme-tui).

## 0. Should it be extracted?

Check it against "When to extract" in the decision doc. If it is engine, edited more
often than it would be bumped, or its dependencies only make sense here, say so and stop.
Ask the user before going further; a new public repo is outward-facing.

## 1. Split the history

`git subtree` is not installed on Fedora by default; `git filter-repo` is. Work in a
fresh clone, never in the user's checkout:

```bash
d=$(mktemp -d) && git clone --no-local ~/dotfiles "$d" && cd "$d"
git filter-repo --subdirectory-filter <path>
```

Check the result before publishing it: `git log --oneline | head`, and grep the tree for
anything the public-repo rule forbids (employer, client, host, personal paths). The source
tree was public, but the history may hold things since removed.

## 2. Make the new repo stand alone

Before anything is pushed, give it what the decision doc requires: `LICENSE`, a README
with an install that does not mention dotfiles, CI, `.github/dependabot.yml`, and a
`CLAUDE.md` holding the docs that move with the code. Remove every path or name from this
repo; replace one with an override variable if a sibling is needed.

Create the GitHub repo and push only with the user's yes (`gh repo create roest1/<name>
--public`, then push). Show them the name, visibility and description first.

## 3. Pin it back here, same path

On a branch in `~/dotfiles`:

```bash
git rm -r -q <path>
git submodule add https://github.com/roest1/<name>.git <path>
```

Use the `https://` URL, like the existing entries: a machine with no SSH key must still
check it out.

## 4. Rewire, in the same commit

- `deps.conf`: link and tool lines still resolve; nothing else should change.
- Workspaces and build files: a Rust component is excluded from `tui/Cargo.toml`'s
  workspace and pinned by its own `Cargo.lock` (see the comment there and `tui/deps.sh`).
- `.github/dependabot.yml`: add it to the `gitsubmodule` entry's comment.
- `.github/workflows/ci.yml`: if it builds, build and test it at the pin.
- Docs: delete what moved; update the submodule bullet in `CLAUDE.md`, the pillar row,
  the README components table, and any `<dir>/CLAUDE.md` that described it.
- `h` in `bash/bash_productivity` if a command's name or home changed.

## 5. Verify

```bash
make link && make status          # links resolve into the submodule, nothing drifted
./tools/lint.sh
```

Plus whatever CI runs for that pillar. Also test a fresh clone: `git clone --recurse-submodules`
into the scratchpad and `make link` there.

Commit message style: `<pillar>: <what> is the roest1/<name> submodule`, body saying what
moved, that history came with it, and what CI now checks at the pin.
