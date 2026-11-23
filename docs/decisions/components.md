# Components and plugins

**Status:** in force since 2026-11-23. Four components so far: `ps1/`, `wezterm/fonts/`,
`tui/font/`, `tui/github/`.
**Applies to:** `.gitmodules`, `lib/submodules.sh`, `lib/plugins.sh`, Dependabot.

Code that is not in this tree reaches a machine one of two ways. They are not
interchangeable, and choosing the wrong one costs either the pin or the privacy.

| | Component (git submodule) | Plugin |
| --- | --- | --- |
| Is | a public repo this one depends on | a repo with its own `deps.conf`, run through this engine |
| Pinned | yes, to a commit recorded here | no, whatever is cloned |
| Dependabot | `gitsubmodule` proposes bumps here weekly | never sees it |
| Listed in | `.gitmodules` and `deps.conf` link lines | `~/.config/dotfiles/plugins`, machine-local |
| On every machine | yes, unless opted out | only where listed |
| For | public pieces you want identical everywhere | private things that cannot be in a public tree |

**Default is everything on.** A component arrives on every machine. Opting out is per
machine and never a tracked diff: leave the section out of `~/.config/dotfiles/sections`,
or `git config submodule.<name>.update none`. An opt-in list would have to be rewritten
on every new machine, which is the drift this repo exists to remove.

## When to extract a component

Extract when the piece has an audience or a cadence of its own. Someone could use it
without these dotfiles (the prompt, a font, a TUI), or it releases on its own schedule.

Do not extract when:

- **It is engine.** `[git-autofetch]` sources `lib/plugins.sh` and finds the clone from its
  own path. Pulling it out would duplicate the plugins file format in a second repo.
- **You edit it more often than you would bump it.** Every change becomes two PRs: a commit
  there, then a pin bump here. Dependabot bumps weekly; anything sooner is a manual bump.
- **Its dependencies only make sense here.** Its Dependabot, `bun audit` and Socket checks
  move with it, and its alerts arrive on its own repo, not this one. The `gitsubmodule`
  ecosystem sees new commits, not advisories.

## What a component must have

In its own repo:

1. Public, with a `LICENSE` (fonts carry their OFL).
2. A README whose install works without this repo.
3. A public configuration surface, such as PS1's `PS1_COLOR_*`/`PS1_ICON_*`. This repo sets
   those variables and never reaches into internals (`__` names, private files).
4. Its own CI and its own `.github/dependabot.yml` for its own dependencies.
5. No path, name or assumption from this repo. It may read an override variable that
   points at a sibling (theme-tui reads `PS1_BASH`, or the `ps1` submodule when present).
6. History moved with it, so `git blame` still works.

In this repo, in one commit:

1. `.gitmodules` entry, mounted **at the path the code already had**, so every link line,
   comment and `font_dirs` entry keeps resolving.
2. `deps.conf` link lines unchanged, or pointing into the submodule.
3. The `gitsubmodule` entry in `.github/dependabot.yml` names it in its comment. The entry
   already covers every submodule; no new entry.
4. CI: `submodules: true` is already on every checkout. If the component builds (Rust),
   CI builds and tests it at the pin.
5. Docs that left with the code are removed here. `CLAUDE.md` names the submodule in the
   "public component" bullet, and the README's components table gets a row.

## What a plugin must have

1. A git repo with `deps.conf` at its root, in this repo's format.
2. Optionally `<section>/deps.sh`, run after that section's tools.
3. Shell code only by linking a `*.bash` file into `~/.config/dotfiles/bashrc.d/`.
4. No assumption beyond the core: the core must work with zero plugins, and a plugin
   must work over a core that has only what `deps.conf` here declares.

The procedure for extracting a component is the project skill
`.claude/skills/extract-component/`.
