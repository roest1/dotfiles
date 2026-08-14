# Duplicate installs across providers

**Status:** open problem, no tool offered yet.
**Applies to:** `make status`, provider resolution, `lib/pkg.sh`.

`deps.conf` declares which provider *should* install a tool. Nothing ever removes the
copy a different provider installed earlier. A `||` chain makes that invisible: every
member of the chain is a correct answer, so `make status` reads "in sync" while three
copies of the same tool sit on disk and PATH order alone decides which one runs.

This is not hypothetical. It is what this machine looked like the day it was written.

## What happened

`mise.toml` pinned versions this machine had never installed. Running `mise install`
fixed that — and silently changed the reported provenance of four tools that nobody
touched:

| tool | before | after | declared |
| --- | --- | --- | --- |
| `shellcheck` | pkg | mise | `pkg\|\|mise` |
| `stylua` | cargo | mise | `mise\|\|cargo` |
| `tree-sitter` | cargo | mise | `pkg\|\|cargo\|\|mise` |
| `bun` | manual | mise | `mise\|\|manual` |

Nothing was uninstalled. The mise shim directory sits earlier on PATH, so the shims now
shadow copies that are still there:

```
$ type -a tree-sitter
tree-sitter is ~/.local/share/mise/shims/tree-sitter
tree-sitter is /home/linuxbrew/.linuxbrew/bin/tree-sitter
tree-sitter is ~/.cargo/bin/tree-sitter
```

Three providers, one tool, and `make status` prints `✓ tree-sitter mise` because `mise`
satisfies `pkg||cargo||mise`. The report is *correct*. It is just answering a narrower
question than the one you have.

## The part that actually matters

The dormant copies are not merely redundant. They are **older and unpinned**:

| dormant copy | version | pinned in `mise.toml` |
| --- | --- | --- |
| `~/.cargo/bin/stylua` | 2.4.0 | 2.5.2 |
| `~/.cargo/bin/tree-sitter` | 0.26.7 | 0.26.12 |

That is precisely the drift `mise.lock` exists to prevent, still present on disk and one
PATH change away from being live again. A machine that loses its shim directory — a
`.bashrc` edit, a stale login shell, a `make`-invoked subshell — silently falls back to a
version no file in this repo names. Reintroducing the old failure mode requires no
install, only a reordering.

Disk cost is real but secondary: 8.0M + 12M + 19M + 89M of shadowed binaries here.

## `mise prune` covers half of it

mise already ships the tool for its own half, and it works:

```
$ mise prune --dry-run
mise lua-language-server@3.18.2 [dryrun]  uninstall
mise qsv@21.1.0 [dryrun]  uninstall
```

That is 347M of superseded mise versions on this machine (qsv 21.1.0 alone is 303M).
`mise prune` is safe, already available, and worth running after any version bump. It
belongs in the workflow regardless of what else gets built.

**It cannot see the other half.** `~/.cargo/bin/stylua`, linuxbrew's `tree-sitter`,
`/usr/bin/shellcheck` and `~/.bun/bin/bun` are outside mise entirely. Nothing in this repo
or in mise knows they are duplicates of a declared tool, because knowing that requires
reading `deps.conf`.

## Why this is computable, unlike "installed but not declared"

`CLAUDE.md` rules out reporting "installed but not declared", and the reasoning holds:
nothing distinguishes a dotfiles dependency from a project-scoped tool, so that list
cannot be computed without an ignore list naming unrelated projects.

**This question is different, and the difference is the whole reason it is worth
building.** The tool is already declared. The question is "how many copies of a tool
`deps.conf` names exist on this machine, and which one wins" — well-defined, computable
from `type -a` plus the manifest, and needing no knowledge of anything outside the repo.
It describes the repo's own dependencies and nothing else, which is the standing rule.

## Sketch, not a commitment

Reporting is the easy, safe half and should come first — a `shadowed` note in
`make status`, or a separate `make doctor`:

```
✓ tree-sitter    mise        2 shadowed (~/.cargo/bin, linuxbrew)
```

Removing them is the half that needs care, and it is not symmetrical across providers.
`cargo uninstall` and `mise uninstall` are per-user and reversible. `pkg` is neither:
`/usr/bin/shellcheck` may be a dependency of something else on the system, uninstalling it
needs sudo, and a dotfiles repo reaching for `dnf remove` is a different class of program
than one that installs into `$HOME`. Any removal must therefore be opt-in, per-provider,
and must refuse `pkg` by default.

Open questions before building:

1. Is `type -a` enough, or does provenance need `provider_of` run against every path? A
   second copy behind the same provider is not the interesting case.
2. Does a shadowed copy count as drift (non-zero exit, CI-visible) or as advice? It is not
   a broken machine, and making `make status` fail on it would make the common state red.
3. Is this `make doctor`, or a fourth column in `status`? `status` currently answers "is
   this machine what the manifest says" and this is arguably a different question.

## Relationship to Nix

This is one of the concrete costs of provider pluralism, and it is worth weighing in
[`nix.md`](nix.md): a true dependency closure does not have this failure mode, because
nothing is installed outside it. That is an argument for Nix, not a decisive one — the
mitigation here is a reporting command, not a rewrite.
