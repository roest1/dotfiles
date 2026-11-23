---
name: extract-component
description: Move a directory of this dotfiles repo into its own public repo and pin it back here as a git submodule at the same path, with history. Use when asked to extract, split out, break out, or spin off part of the dotfiles (a TUI, the nvim config, a font, a script) into its own repo, or to judge whether something should be.
---

# Extract a component

The rules are `docs/decisions/components.md`. Read it first; this file is the order of
operations and the traps each past extraction hit. Copy from them: `git show 71673f0`
(ps1), `b1ee76c` (fonts), `82fce00` (github-tui), `6ca35aa` (theme-tui). tui-core is the
other shape, a Cargo git dependency rather than a submodule (roest1/dotfiles#133).

Never switch, reset or commit on the user's `~/dotfiles` checkout to do this; another
session may own its branch. Work on a new branch, and in scratch clones.

## 0. Should it be extracted?

Check "When to extract" in the decision doc. Measure the edit rate rather than guess:
`git log --oneline --since=30.days origin/main -- <path> | wc -l`. If it is engine, edited
more often than it would be bumped, or its tools are installed by a section here, say so
and stop. Ask before going further: a new public repo is outward-facing.

## 1. Split the history

From GitHub's `main`, never the local checkout, which may be on any branch. List every
path that leaves, not only the directory (fonts took `wezterm/mkmono.py`; github-tui took
three docs from `docs/`):

```bash
git clone -q https://github.com/roest1/dotfiles.git "$S/<name>" && cd "$S/<name>"   # $S: the scratchpad
git filter-repo --path <dir>/ --path <other file> --path-rename <dir>/:
git log --format='%an <%ae>' | sort -u      # noreply addresses only
git log -p | grep -nE '(/home/|/Users/)[A-Za-z]|<employer/client/host names>'
```

The second grep is over history, not the tree: the tree was public, but history may
hold what was removed since.

## 2. Make it stand alone

- `LICENSE` (copy this repo's MIT; fonts carry their OFL), `.github/CODEOWNERS` (`* @roest1`),
  `.gitignore` (`target/` for Rust).
- README: what it is, and an install that needs nothing from here.
- `CLAUDE.md`: the entries that leave with the code, moved as they are (trim later, there).
  Move whole entries by their `- **` starts; `<dir>/CLAUDE.md` here keeps a pointer.
- `.github/dependabot.yml`: copy roest1/github-tui's (cargo and actions, monthly, cooldown
  7, tui-core excluded from the cooldown).
- `.github/workflows/ci.yml`: copy roest1/github-tui's. It must keep a job named exactly
  **`ci ok`**: the copied ruleset requires that context, and without it nothing merges.
  Actions pinned by SHA, to a release at least 7 days old.
- No build or test dependency on this repo's paths. Mentions in prose are fine. A sibling
  it truly needs comes through an override variable that CI sets (theme-tui's `PS1_BASH`),
  and a missing sibling fails the test rather than skipping it.

**Rust:**
- Replace each `<key>.workspace = true` by whole-line match. A plain replace of `version`
  also rewrites `rust-version`.
- tui-core is `tui-core = { git = "https://github.com/roest1/tui-core", branch = "main" }`,
  byte for byte. Any other spec is a second copy, and types stop matching.
- Copy `tui/Cargo.lock` in, then run `cargo metadata` to prune it: no version moves.
  Compare the two package sets before committing.
- Run fmt, `clippy --all-targets --locked -- -D warnings` and `test --locked`.

## 3. Create the repo (with the user's yes)

Show the name, visibility and description first. Then publish, and copy PS1's settings:

```bash
gh repo create roest1/<name> --public --description "…" --source . --remote origin --push
gh repo edit roest1/<name> --enable-wiki=false --enable-projects=false --delete-branch-on-merge \
  --enable-squash-merge=false --enable-rebase-merge=false --enable-merge-commit --add-topic <topics>
gh api -X PATCH repos/roest1/<name> -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
gh api -X PUT repos/roest1/<name>/vulnerability-alerts
gh api -X PUT repos/roest1/<name>/automated-security-fixes
for id in $(gh api repos/roest1/PS1/rulesets -q '.[].id'); do
  gh api repos/roest1/PS1/rulesets/$id -q '{name,target,enforcement,conditions,rules,bypass_actors}' |
    gh api -X POST repos/roest1/<name>/rulesets --input -
done
```

Wait for its first CI run to pass. Its `main` is protected from here on: later fixes there
go through a PR.

## 4. Pin it back here, same path, one commit

On a new branch from `origin/main`:

```bash
git rm -r -q <path> <other files that moved>
rm -rf <path>            # ignored leftovers (target/) make `submodule add` refuse
git submodule add https://github.com/roest1/<name>.git <path>
```

`https://`, like the other entries: a machine with no SSH key must still check it out.
Then rewire:

- `deps.conf`: link and tool lines resolve as before. Fix comments that cite moved docs.
- Rust: add it to `exclude` in `tui/Cargo.toml`. A crate here that used it by path keeps
  the path dep into the submodule (`dots` → `../font`), so it still builds against one
  tui-core. `tui/Cargo.lock` should lose only the moved package, or nothing.
- CI: build and test it at the pin. Then grep `ci.yml` for anything that lists the old
  location or paths into its build output (`members`, `tui/target/release/<bin>`): those
  lose coverage silently instead of failing.
- `.github/dependabot.yml`: name it in the `gitsubmodule` entry's comment. The entry
  already covers every submodule.
- Docs: `CLAUDE.md`'s submodule bullet and pillar row, the README components table,
  links to docs that moved (point them at the new repo), `h` if a command changed.

## 5. Verify

- The pillar's own checks, `./tools/lint.sh`, `tools/check-content.sh`, and actionlint
  showing the same notes as `main`.
- `make install <section>` here, then run what it installed.
- **An existing clone pulling the change**, which is the case that breaks. A fresh
  `--recurse-submodules` clone always works:

  ```bash
  git clone -q --recurse-submodules https://github.com/roest1/dotfiles.git "$S/sim" && cd "$S/sim"
  git config core.hooksPath .githooks && git config submodule.recurse true
  git fetch -q ~/dotfiles <branch> && git merge --ff-only FETCH_HEAD
  git submodule status      # the new one checked out by .githooks/post-merge
  ```

  Git's own "Could not access submodule" line during that pull is expected; the hook
  follows it.

Commit message: `<pillar>: <what> is the roest1/<name> submodule`, with a body saying
what moved, that history came with it, and what CI now checks at the pin.

## After the merge

Local `main` will refuse to switch: the files that moved are untracked where the
submodule now sits. If `git rev-list --count origin/main..main` is 0, then
`git switch -C main origin/main`.
