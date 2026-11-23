# dotfiles

Terminal, editor and shell as one versioned unit — wezterm, neovim and bash in a
single repo, with every symlink and every dependency declared in one manifest.
Fedora and RHEL.

## Install

One line on a fresh machine — installs git if needed, clones, and runs `make install`:

```sh
curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
```

Already cloned? `cd ~/dotfiles && make install`, then `exec bash`.

## What you get

Each section of `deps.conf` is one pillar. Install them all, or name the ones you want
(`make install bash nvim`).

| Pillar | What it gives you |
| ------ | ----------------- |
| `[bash]` | `~/.bashrc`, colors, the prompt, everyday commands (`h` lists them), git and `gh` helpers, `~/.gitconfig` |
| `[uv]` | Astral's uv, kept self-updating, for Python tools |
| `[nvim]` | Neovim config with language servers and formatters ([nvim/README.md](nvim/README.md)) |
| `[wezterm]` | The terminal config and the Science Gothic Mono font |
| `[tui]` | Terminal apps: `github` (the current repo on GitHub, live; [roest1/github-tui](https://github.com/roest1/github-tui)), `dots` (this repo's console), `font` (pick fonts per lane; [roest1/theme-tui](https://github.com/roest1/theme-tui)) |
| `[claude]` | Claude Code settings: deny rules for secrets, terminal status hooks |
| `[git-autofetch]` | Fetches this repo, its plugins and `~/github` every 20 minutes, never pulls, and tells each new shell when you are behind |

### Just want the prompt?

The bash prompt is its own repo, [roest1/PS1](https://github.com/roest1/PS1): one file
with a two-line install. Here it is a git submodule at `ps1/`, pinned to a commit and
bumped by Dependabot, so a change there reaches your machines only through a PR in this
repo. Its colors and icons are `PS1_COLOR_*` and `PS1_ICON_*` variables
([list](https://github.com/roest1/PS1#colors-and-icons)); here they go in
`~/.bash_local`, which bashrc loads before the prompt.

Dependabot proposes a bump weekly. To bump now, move the pin to PS1's `main` and open
the same PR it would:

```bash
git switch -c ps1-bump
git submodule update --remote ps1
git commit -am "ps1: bump"
gh pr create --fill
```

Once it merges, every machine gets it on `git pull`. The fonts at `wezterm/fonts`
([roest1/fonts](https://github.com/roest1/fonts)), `font` at `tui/font`
([roest1/theme-tui](https://github.com/roest1/theme-tui)) and `github` at `tui/github`
([roest1/github-tui](https://github.com/roest1/github-tui)) bump the same way. The TUIs' framework,
[roest1/tui-core](https://github.com/roest1/tui-core), is a Cargo dependency: bump it with
`cargo update -p tui-core --manifest-path tui/Cargo.toml`.

## Everything lives in `deps.conf`

One file declares every config symlink and every dependency. **Toggling is
commenting** — there's no flag to remember and no profile vocabulary to learn.

```conf
[nvim]
link  nvim                    ~/.config/nvim
tool  mise||pkg    nvim       neovim     # mise first: RHEL 9's is too old
tool  mise||cargo  stylua
tool  uv||pkg      ruff
# tool  pkg        shfmt                 ← commented out = skipped
post  bun install --cwd nvim/lsp-servers --frozen-lockfile
```

| Line | What |
| ---- | ---- |
| `link <repo-path> <dest>` | a symlink; `~` expands to your home |
| `tool <provider> <command> [package]` | a dependency; package defaults to the command name |
| `post <shell command>` | runs after that section's tools |

| Command | What |
| ------- | ---- |
| `make install` | everything enabled in `deps.conf` |
| `make install nvim` | one section (repeatable: `make install bash nvim`) |
| `make link` | symlinks only — no sudo, no network, nothing downloaded |
| `make check` | is each enabled tool present? |
| `make status` | is this machine what `deps.conf` says — links, and which provider installed each tool? |
| `make sections` | list sections |
| `make help` | everything else |

**Adding a program is a new section plus its config file**, and no other edits: the
`Makefile` reads sections from the manifest.

To skip a section on one machine without editing the tracked file, list the sections you
want in `~/.config/dotfiles/sections` (`make sections > ~/.config/dotfiles/sections`, then
comment out lines). The one-liner takes a subset too: `DOTFILES_TARGET=bash curl ... | bash`.

### Providers

Each `tool` line names how to install it; `||` is a fallback chain, tried left to right.

| Provider | Use |
| -------- | --- |
| `pkg`    | the system package manager, dnf |
| `mise`   | tools distros don't reliably carry — pinned versions, checksummed downloads |
| `uv`     | Python tools (replaces pip) |
| `cargo`  | compiles from source — slow, prefer `mise` |
| `manual` | an official installer or extracted build is the source; the install lives in the section's `deps.sh` |

**No node, npm or pip anywhere.** The toolchain is bun and uv; the JavaScript language
servers run as `bun <path>`, and CI proves each one completes a real LSP handshake with
node absent. `[bash]` is near-pure `pkg`, so a locked-down machine can install the whole
shell without a curl-piped installer.

`./tools/adopt.sh <command>` prints a correct `tool` line for something already installed
(provider and package name). It never edits `deps.conf`.

## Plugins

Other repos can ride the same engine: a repo with its own `deps.conf` is a plugin. List the
ones a machine wants in `~/.config/dotfiles/plugins` (machine-local, never in this repo):

```conf
# name   git-url                            [clone dir]
roest    git@github.com:roest1/roest.git    ~/roest
```

`make install` clones what is missing and installs it; `make link`, `check` and `status`
include plugins; naming a section (`make install bash`) leaves them alone. No file means no
plugins, and one you cannot clone is skipped — the core never needs any. A plugin adds shell
code by linking a `*.bash` file into `~/.config/dotfiles/bashrc.d/`, which `~/.bashrc`
sources last.

## Machine-local config

Two files hold host-specific setup, sourced by `bashrc` when they exist:

```sh
touch ~/.bash_local && chmod 600 ~/.bash_local                          # paths, exports, PS1 colors
touch ~/.bash_password_commands && chmod 600 ~/.bash_password_commands  # anything sensitive
```

**They live in `$HOME`, not in this repo, and that is the security design:** git cannot
commit a file outside its work tree. A gitignored file inside the repo would be protected
only by a rule that `git add -f` overrides. Two layers catch a secret file created inside
the repo anyway:

| Layer | Catches |
| ----- | ------- |
| `.githooks/pre-commit` | a staged secret, before the commit exists |
| CI: *No secret or machine-local files are tracked* | anything that got past the hook, before it reaches `main` |

Both read [`.githooks/secret-patterns`](.githooks/secret-patterns), and `install.sh` turns
the hook on with `core.hooksPath`. GitHub's push protection is on for this repo as a third.

## Layout

```
deps.conf        THE MANIFEST — links + dependencies
Makefile         reads sections from deps.conf
bootstrap.sh     curl-able fresh-machine entry point
install.sh       symlinks (backs up what it replaces, prunes orphaned links)
lib/             the engine: parser, providers, installers, status, plugins
tools/           adopt.sh, usage.sh, mise and lint helpers
bash/            [bash] — bashrc and the files it sources
ps1/             submodule: roest1/PS1, linked as ~/.bash_prompt
git/             gitconfig, plus GitHub setup notes
uv/              [uv]
nvim/            [nvim] — its own Makefile and README
wezterm/         [wezterm] — config; fonts/ is roest1/fonts
tui/             [tui] — dots; font/ and github/ are roest1/theme-tui, roest1/github-tui
claude/          [claude]
git-autofetch/   [git-autofetch] — the script, its systemd units, the shell notice
docs/decisions/  why things are the way they are
```

## Portability is tested, not claimed

`.github/workflows/ci.yml` runs `make link` and full installs in Fedora 45 and RHEL 9
(AlmaLinux) containers, plus shellcheck, manifest validation and supply-chain checks, on
every push.

## Contributing

Portability fixes and machinery bugs are welcome; personal-preference changes
aren't (fork instead — the layout is built for it). See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT ([LICENSE](LICENSE)). The fonts at `wezterm/fonts/` are the [roest1/fonts](https://github.com/roest1/fonts) submodule, under the OFL.
