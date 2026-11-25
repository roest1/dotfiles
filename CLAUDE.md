# CLAUDE.md

Shell, editor and terminal as one versioned unit, for Fedora Workstation (GNOME) and RHEL.
Bash. **This repo is public:** no employer, client, host or personal detail goes in the
tree; those belong in a private plugin (below).

Not supported: macOS since 2026-10-26, Windows/WSL/Ubuntu since 2026-11-21. GNU
spellings are fine; the portable constructs left in the tree cost nothing, so leave them.
What was removed and how to bring it back: [`docs/decisions/macos.md`](docs/decisions/macos.md),
[`docs/decisions/windows-wsl.md`](docs/decisions/windows-wsl.md).

## Pillars

Each `deps.conf` section is a pillar, and the sections are the whole list of what this repo
installs. Docs for a pillar live next to its code; this file holds only what crosses pillars.

| Pillar | What it gives a machine | Read before editing |
| --- | --- | --- |
| `[bash]` | `~/.bashrc`, colors, commands (`h`), git and `gh` helpers, `~/.gitconfig`, the prompt | `ps1/` is [roest1/PS1](https://github.com/roest1/PS1) |
| `[uv]` | Astral's self-updating uv and its config | "Providers" below |
| `[nvim]` | the editor, its plugins and language servers | [`nvim/CLAUDE.md`](nvim/CLAUDE.md) |
| `[wezterm]` | the terminal, Science Gothic Mono, the `mux` domain | [`wezterm/CLAUDE.md`](wezterm/CLAUDE.md) |
| `[tui]` | Rust TUIs: `dots`, plus `theme` (roest1/theme-tui at `tui/theme`) and `github` (roest1/github-tui at `tui/github`) | [`tui/CLAUDE.md`](tui/CLAUDE.md) |
| `[claude]` | Claude Code settings and hooks | the `[claude]` comment block in `deps.conf` |
| `[git-autofetch]` | a timer that fetches (never pulls) this clone, its plugins and `~/github`, and says when a machine is behind | the `[git-autofetch]` comment block in `deps.conf` |

Under them all is the engine: `Makefile`, `install.sh`, `bootstrap.sh`, [`lib/`](lib/CLAUDE.md).

## `deps.conf` is the source of truth

Every config symlink and every dependency is declared in `deps.conf`. Nothing else
enumerates them; the `Makefile` reads sections from the manifest and does not know what a
"bash" or an "nvim" is. See `make help`.

- **Adding a program = a new section plus its config file.** No Makefile, install.sh or
  bootstrap.sh edits. If you are editing those to add a tool, you're doing it wrong.
- **Toggling is commenting.** No `WITHOUT=` flag, no profiles, no "areas"; that abstraction
  was removed because it earned nothing over a section named after the program.
- **Skipping a section on ONE machine goes in `~/.config/dotfiles/sections`**, never in
  `deps.conf`, where it would be a tracked diff. Seed it with
  `make sections > ~/.config/dotfiles/sections`. Absent means every section; present means
  exactly the names in it, so a section added later arrives **off** there. Naming a section
  (`make install claude`) always wins. An unknown name warns; an all-commented file refuses
  rather than falling through to "all". `make status` names the sections it skipped. `dots`
  writes this file and shows which of the two states is in force ([`tui/CLAUDE.md`](tui/CLAUDE.md)).
- **Plugins are other repos run through this engine** (`lib/plugins.sh`): a git repo with
  its own `deps.conf`, listed per machine in `~/.config/dotfiles/plugins` (machine-local,
  because the list names private repos). Every path resolves from `MANIFEST_ROOT`, the
  manifest's own directory; never reintroduce a hard-coded repo root. Bare
  `make install`/`link`/`check`/`status` include plugins, a named section never does, and
  `make link` never clones. **The core must work with zero plugins**: no file means none,
  and one that cannot be cloned is skipped. Personal things (the global `CLAUDE.md`,
  employer URL rules, ssh config, the agent git identity) belong in a private plugin; CI
  rejects a global prompt coming back. A plugin's shell code goes in
  `~/.config/dotfiles/bashrc.d/*.bash`, which `bashrc` sources last.
- **A public component this repo depends on is a git submodule, not a plugin**
  ([`docs/decisions/components.md`](docs/decisions/components.md); to extract one, the
  `extract-component` skill). The prompt
  is `roest1/PS1` at `ps1/`, linked to `~/.bash_prompt`; Science Gothic Mono is
  `roest1/fonts` at `wezterm/fonts/`; the TUIs `theme` and `github` are
  `roest1/theme-tui` at `tui/theme` and `roest1/github-tui` at `tui/github`. A submodule pins a commit, so a push
  there reaches machines only through a bump PR here (Dependabot `gitsubmodule`), after CI;
  a plugin is never pinned. `make install` checks out a submodule that is not checked out
  and never touches one that is; `install.sh` sets `submodule.recurse` so `git pull` follows
  the pin, and `.githooks/post-merge` checks out a submodule a pull or branch switch adds
  (`lib/submodules.sh`). Keep one off a machine with `git config submodule.<name>.update none`.
  A link whose source is missing is skipped, never backed up. To change the
  prompt, change roest1/PS1, then bump here. Its colors and icons are the public
  `PS1_COLOR_*`/`PS1_ICON_*` variables, set in `~/.bash_local`; never reach into its `__`
  internals.

## Checking a machine

`make check` asks "does this command exist". `make status` asks "is this machine what the
manifest says": link targets, per-tool provenance, and the font lanes. Prefer `status`
when the question is whether the repo still tells the truth. Its font block counts only
what a program can prove ([`lib/CLAUDE.md`](lib/CLAUDE.md)).

- It does **not** report "installed but not declared". Nothing distinguishes a dotfiles
  dependency from a project-scoped tool, and suppressing the noise meant naming unrelated
  projects in `deps.conf`. Don't reintroduce an ignore list.
- It **does** report duplicate installs, as advice that never touches the exit code: a `||`
  chain is satisfied by any member, so PATH order alone decides which copy runs. Copies are
  compared by resolved path. Removal is manual:
  [`docs/decisions/tool-duplication.md`](docs/decisions/tool-duplication.md).
- **A linuxbrew copy is `brew`, never `pkg`**, and `manual`'s wildcard does not absorb it.

## Providers

**Don't add install logic.** `lib/pkg.sh` holds the only implementation of "install a tool"
(`pkg_install`, `uv_install`, `mise_install`, `cargo_install`), dispatched by
`lib/providers.sh`. Every helper short-circuits on `command -v`, which makes overlapping
tools safe. `mise_install` is the exception: it reinstalls when the global mise entry is not
`mise.toml`'s pin, or a bumped pin would never reach a machine that has the tool.

- Prefer `pkg` for anything the distro ships, `mise` for what distros don't reliably carry,
  and `||` chains over conditionals. Which provider goes first is a rule:
  [`docs/decisions/toolchain-policy.md`](docs/decisions/toolchain-policy.md).
- **Never key provider choice on `$PM`.** It is a proxy for facts it can't see; write
  `pkg||cargo` and let the chain decide.
- `manual` installs nothing. It declares that an official installer or extracted build is
  an acceptable source (wezterm in `~/.local`, bun's installer), so `make status` doesn't
  flag it. The install itself goes in the section's `deps.sh`, which is also where genuinely
  conditional logic lives (`lib/run.sh` runs it after the section's tools).
- **`[uv]` prefers the official installer over `pkg` on purpose.** The distro's uv has
  `uv self update` compiled out, and no chain can express that: `manual||pkg` would install
  the distro copy first. So `ensure_uv` in `lib/pkg.sh` curls astral.sh and falls back to
  `pkg` only offline; `uv/deps.sh` reports a distro uv but never removes it. That is why uv
  is not in `[bash]` (which may not depend on a curl-piped installer) and why `uv/uv.toml`
  is tracked (its settings came from an RPM-owned `/etc/uv/uv.toml`).
- **`[tui]` declares its binaries `manual`, never `cargo`.** The cargo provider installs by
  crate NAME from crates.io, and `theme` belongs to someone else there. `tui/deps.sh` runs
  `cargo install --path` and fails loudly without a toolchain; opting out of the section is
  the escape hatch. A bash function may never share a name with one of these binaries.
- **`mise.toml` and `mise.lock` are generated** by `tools/gen-mise.sh` from `deps.conf`. Run
  `make mise-lock` after touching a mise tool; versions may be hand-edited, the tool list
  may not. Renovate bumps the pins.
- Nix is deferred; adopting it would be a `nix` provider, not a rewrite:
  [`docs/decisions/nix.md`](docs/decisions/nix.md).

## Footguns

- **`make` never reads `.bashrc`**, so the Makefile sets `PATH` itself (`~/.local/bin`,
  mise shims, `~/.cargo/bin`, `~/.bun/bin`). Without it `make check` reports false MISSINGs.
- **`EDITOR` is set unconditionally to `nvim`**, before `~/.bash_local`. A `${EDITOR:-nvim}`
  default loses to Fedora's `/etc/profile.d/nano-default-editor.sh`. Overrides go in
  `~/.bash_local`.
- **No node, npm or pip. Don't reintroduce them, and never add a `node` shim**: aliasing
  node to bun makes incompatibilities surface as errors blaming the wrong tool. JS tools run
  under bun ([`nvim/CLAUDE.md`](nvim/CLAUDE.md)). CI rejects node/npm/pip in the manifest and
  any shim. That is about this repo and nvim, not the machine: a project (Astro, Vite,
  wrangler) runs on node, with bun as its package manager. Here it is `bun`, never `bunx`,
  because what `bunx` fetches is in no lockfile
  ([`docs/decisions/bun.md`](docs/decisions/bun.md)).
- **Terminal escapes go through `lib/sgr.sh` or `lib/tty.sh`, never raw.** SGR 6 and SGR 5
  are font carriers only inside WezTerm running this config; everywhere else they blink.
  Both blink attributes are taken; there is no third carrier.
  [`lib/CLAUDE.md`](lib/CLAUDE.md), [`wezterm/CLAUDE.md`](wezterm/CLAUDE.md).
- **`wezterm/wezterm.lua` declares the `mux` domain other tools connect to**; don't replace
  it with a stock config. Debug wezterm by suspecting a stale process first
  ([`wezterm/CLAUDE.md`](wezterm/CLAUDE.md)).
- **The fonts in `wezterm/fonts/` are read via `font_dirs`**, never installed system-wide.
  They are the `roest1/fonts` submodule, which generates them and carries their OFL. Every
  other font is installed by that submodule's `install.sh` from its catalogue; don't add a
  download to `wezterm/deps.sh` ([`wezterm/CLAUDE.md`](wezterm/CLAUDE.md)).
- **`~/.gitconfig` is a symlink into the repo, so `git config --global` is a tracked edit.**
  So is `gh auth setup-git`: answer **no** to gh's *"Authenticate Git with your GitHub
  credentials?"*. GitHub auth is SSH. `git/gitconfig` declares no credential helper and
  rewrites only this account's owners to `git@github.com:`; a bare `https://github.com/`
  rewrite would break nvim's plugin clones on a machine with no key. CI rejects both. (A
  `helper = store` here once left a plaintext token on every machine.)
- **After editing `claude/settings.json`, run `claude doctor </dev/null`** and read its
  `Invalid settings` block. Claude Code silently skips a malformed entry, so a typo in a
  hook or deny rule just disappears. `doctor` misses bad enum values; the `$schema` line
  covers those in nvim. Where schema and `doctor` disagree, `doctor` wins.

## Conventions

- **Fedora and RHEL only, both dnf, bash 5.** There is no `_OS` variable and no WSL
  detection. Test on Fedora 45 and RHEL 9.
- **Optional tools are guarded with `command -v`** (`zoxide`, `fzf`, `bat`, `eza`, `fd`,
  `ripgrep`, `gh`, `jq`, all in `[bash]`); features degrade, never fail.
- **`install.sh` hard-codes no filenames** and **prunes orphans**: a symlink into this repo
  whose target is gone is removed. That test is structural on purpose; don't replace it
  with a list of old names.
- **`h` is hand-maintained.** Adding, renaming or removing a command means editing `h` in
  `bash_productivity` in the same commit; CI checks both directions.
- **The `[bash]` file split:** `bash_git` (git porcelain) → `bash_github` (plain
  `gh` and shared helpers). An interactive screen growing back into `bash_github` is drift;
  screens are Rust TUIs. History: roest1/github-tui's
  [`docs/decisions/github-tui.md`](https://github.com/roest1/github-tui/blob/main/docs/decisions/github-tui.md).
- **There are no interactive fzf commands left**, and fzf has no version floor. Only fzf's
  own Ctrl+R / Ctrl+T / Alt+C remain. Don't add a floor back without a caller that needs it:
  a floor cannot fail safe. If an fzf screen is ever wanted again, restore the menu
  wrappers *and* their CI row from git history together.
- **Pruning is measured, and the measurements live in `$HOME`.** `~/.bash_history`
  (dated, appended every prompt) and `~/.local/state/nvim/keymap-usage.json`
  (`:KeymapUsage`). `tools/usage.sh` prints both, zeros first. Never add a log inside the
  repo or under `~/.config/nvim` (a symlink into it). One machine's zero is one machine's
  evidence.
- **Machine-local config lives in `$HOME`, never in the work tree:** `~/.bash_local`
  (per-machine paths and exports) and `~/.bash_password_commands` (secrets), optionally
  sourced by `bashrc` and deliberately absent from `deps.conf`. Don't "tidy" them into
  `bash/` with a `.gitignore` entry; outside the tree git cannot see them at all.
- **The README is concise**: install, pillars, layout, machine-local config. Explanations
  belong in a `CLAUDE.md` next to the code or in `docs/decisions/`.
