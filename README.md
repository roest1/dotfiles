# dotfiles

Personal configuration files — bash and neovim in one repo. Cross-platform (macOS + Linux/WSL + RHEL).

## Install

One line on a fresh machine — installs git if needed, clones, and runs `make install`:

```sh
curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
```

Already cloned? `cd ~/dotfiles && make install`, then `exec bash`.

## Everything lives in `deps.conf`

One file declares every config symlink and every dependency. **Toggling is
commenting** — there's no flag to remember and no profile vocabulary to learn.

```conf
[nvim]
link  nvim                    ~/.config/nvim
tool  pkg   nvim        neovim
tool  mise  stylua
tool  uv    ruff
# tool  npm   prettierd   @fsouza/prettierd    ← disabled: no node on this box
post  make -C nvim sync
```

| Command | What |
| ------- | ---- |
| `make install` | everything enabled in `deps.conf` |
| `make install nvim` | one section (repeatable: `make install bash nvim`) |
| `make link` | symlinks only — no sudo, no network, nothing downloaded |
| `make check` | verify what's enabled is actually present |
| `make sections` | list sections |

Sections are named after the program, so there's nothing to name: `[bash]`,
`[nvim]`, `[wezterm]`, `[dev]`. The `Makefile` reads them from the manifest —
**adding a program is a new section plus its config file, and no other edits.**

### Installing a subset

The real constraint at work usually isn't "no neovim," it's "not *that*
dependency." So granularity goes down to the individual tool:

- **Skip one tool** — comment its line.
- **Skip a whole program** — `make install bash` instead of `make install`.
- **Install nothing at all** — `make link` gives you every config with no sudo
  and no network.

Scope the one-liner the same way: `DOTFILES_TARGET=bash curl ... | bash`.

**The node case is worth knowing before you need it.** Commenting out the node
block in `[nvim]` leaves a working editor — `lsp.lua` drops the JS-based
language servers when `node` is absent, so you keep clangd (C/C++), lua_ls and
lemminx, and lose ts/css/html/json/yaml/bash plus prettier and eslint_d. Those
six *are* JavaScript programs and Mason shells out to `npm` specifically, so no
packaging trick and no bun substitution avoids it. Good subset for C++/Lua work;
not a subset for web work. CI exercises this path on every push.

### Providers

Each `tool` line names how to install it. `||` declares a fallback chain:

| Provider | Use |
| -------- | --- |
| `pkg`    | system package manager (brew / apt / dnf) |
| `mise`   | tools distros don't reliably carry — pinned versions, binary downloads |
| `npm`    | `npm -g` (needs node) |
| `uv`     | Python tools (replaces pip; same vendor as ruff) |
| `cargo`  | compiles from source — slow, prefer `mise` |

```conf
tool  pkg||cargo  eza     # distro package if it exists, else compile
```

`[bash]` is deliberately pure `pkg`, so a locked-down machine can install the
whole shell without mise, node, or any curl-piped installer.

## Layout

| Path | What |
| ---- | ---- |
| `deps.conf` | **the manifest** — links and dependencies, one file |
| `bootstrap.sh` | Curl-able entry point for a fresh machine |
| `install.sh`   | Symlinks only; walks the manifest's `link` lines |
| `lib/manifest.sh` | Parses `deps.conf` |
| `lib/providers.sh` | Maps a provider name to an installer; handles `\|\|` chains |
| `lib/pkg.sh`   | The single implementation of "install a tool" |
| `lib/run.sh`   | Installs a section's tools, runs `post` steps and platform fixups |
| `bash/`, `nvim/`, `wezterm/` | Config, plus an optional `deps.sh` for platform-conditional fixups |

`nvim/` is self-contained — its own Makefile and README — so it still stands
alone despite living here.

## Portability is tested, not claimed

`.github/workflows/ci.yml` runs on every push: `make link` on Ubuntu and macOS,
full installs across apt / brew / dnf, shellcheck, manifest validation, and a
job that comments out the node block and asserts nvim still starts clean.

This exists because the previous Makefile promised WSL support in this README
while `make deps` hard-exited on apt. Nothing ever ran it on Ubuntu, so nobody
noticed.

## GitHub Terminal Tools

**[Full walkthrough → git/GITHUB_TOOLS.md](git/GITHUB_TOOLS.md)** — walkthroughs and demos for the interactive GitHub tools.

Start with `gh-ui` for the unified hub, or jump directly to:

| Command | What |
| ------- | ---- |
| `gh-ui`     | Unified interactive GitHub hub |
| `gpr`       | PR management with filters |
| `gha-ui`    | Workflow run picker with smart log view |
| `ghsecrets` | Repository secrets |
| `ghbranch`  | Branch management |
| `ghenv`     | Environment management |

## Layout

<details>
<summary>Directory tree</summary>

```
~/dotfiles/
├── deps.conf                             THE MANIFEST — links + dependencies
├── Makefile                              Reads sections from deps.conf
├── bootstrap.sh                          Curl-able fresh-machine entry point
├── install.sh                            Symlink engine (backs up existing files)
├── lib/
│   ├── manifest.sh                       deps.conf parser
│   ├── providers.sh                      provider dispatch + || chains
│   ├── pkg.sh                            the installers
│   └── run.sh                            section runner
├── nvim/                                 Neovim config (own Makefile + README)
├── wezterm/
│   └── wezterm.lua                     → ~/.config/wezterm/wezterm.lua
├── bash/
│   ├── bashrc                          → ~/.bashrc
│   ├── bash_roest_theme                → ~/.bash_roest_theme
│   ├── bash_roest_productivity         → ~/.bash_roest_productivity
│   ├── bash_roest_git                  → ~/.bash_roest_git
│   ├── bash_roest_github               → ~/.bash_roest_github
│   ├── bash_roest_local                → ~/.bash_roest_local               (untracked)
│   └── bash_roest_password_commands    → ~/.bash_roest_password_commands   (untracked)
├── git/
│   ├── gitconfig                       → ~/.gitconfig
│   ├── README.md                         GitHub tips and tricks
│   └── GITHUB_TOOLS.md                   Interactive tools walkthrough
├── podman/
│   └── README.md                         podman container-engine reference (Linux)
└── systemd/
    └── README.md                         systemctl / journalctl reference (Linux)
```
</details>

Neovim config lives in `nvim/` — merged in from the former `roest1/nvim` repo with
its full history. It keeps its own `Makefile` and `README.md` so the directory
still stands alone.

## What goes where

| File                                | Controls                                                             |
| ----------------------------------- | -------------------------------------------------------------------- |
| `bash/bashrc`                       | Shell options, PATH, package managers, sources theme + productivity  |
| `bash/bash_roest_theme`             | Prompt, colors, LS_COLORS, man page colors                           |
| `bash/bash_roest_productivity`      | Custom commands, aliases, `h` help system                            |
| `bash/bash_roest_git`               | GitHub Actions tools (`gha`, `gha-ui`, `gha-fail`, `gha-open`)       |
| `bash/bash_roest_github`            | Unified GitHub hub (`gh-ui`) + `gpr`, `ghsecrets`, `ghbranch`, `ghenv` |
| `bash/bash_roest_local`             | Machine-specific config — CUDA, nvim path, etc. (untracked)          |
| `bash/bash_roest_password_commands` | Sensitive commands (untracked)                                       |
| `podman/README.md`                  | `podman` container-engine reference (Linux/RHEL)                     |
| `systemd/README.md`                 | `systemctl` / `journalctl` reference (Linux/RHEL)                    |

## Machine-local config

Create either file for host-specific setup. Both are gitignored and sourced by `bashrc`:

```sh
touch ~/dotfiles/bash/bash_roest_local              # CUDA paths, per-machine exports
touch ~/dotfiles/bash/bash_roest_password_commands  # secrets
```

> **Note:** filenames in `bash/` and `git/` are hard-coded in `install.sh`. Edit the script if you add or rename files.

## License

MIT
