# dotfiles

Personal configuration files — bash and neovim in one repo. Cross-platform (macOS + Linux/WSL + RHEL).

## Install

One line on a fresh machine — installs git if needed, clones, and runs `make all`:

```sh
curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
```

Already cloned? `cd ~/dotfiles && make all`, then `exec bash`.

## Install only what you're allowed to

Two axes: **which area**, and **how far** (symlink only, or also install tools).

|            | symlink only     | symlink + tools |
| ---------- | ---------------- | --------------- |
| bash       | `make link-bash` | `make bash`     |
| nvim       | `make link-nvim` | `make nvim`     |
| dev        | —                | `make dev`      |
| everything | `make link`      | `make all`      |

- **`make bash`** — complete working shell with no editor involved. For a machine where neovim isn't permitted. The `n`/`nv`/`nvi` shortcuts belong to the nvim area and simply won't exist; `f` and `dotfiles-edit` use `$EDITOR`, which you can point at `vim` in `~/.bash_roest_local`.
- **`make link`** — every config symlinked, nothing installed. No sudo, no network. For a locked-down box.
- **`make dev`** — project runtimes (bun) only. Kept separate because a work machine may forbid curl-pipe installers even where symlinking a bashrc is fine.

Scope the one-liner the same way: `DOTFILES_TARGET=bash curl ... | bash`.

**Tools by area** — `fd` and `rg` are wanted by both; the installers short-circuit on `command -v`, so they're installed once.

| Area | Tools |
| ---- | ----- |
| bash | zoxide, fzf, bat, eza, fd, ripgrep, gh, jq (+ bash 5 on macOS, which ships 3.2) |
| nvim | neovim, node, npm, python3, tree-sitter, stylua, prettier, prettierd, ruff, eslint_d |
| dev  | bun |

**Verify:** `make check` (or `check-bash` / `check-nvim` / `check-dev`).

**Other targets:** `make shell` (set default shell to bash), `make update` (git pull + re-link), `make sync` (nvim plugins + parsers).

## Layout

| Path | What |
| ---- | ---- |
| `bootstrap.sh` | Curl-able entry point for a fresh machine |
| `install.sh`   | Symlinks only; takes area args (`bash`, `nvim`) |
| `lib/pkg.sh`   | The single implementation of "install a tool", shared by all areas |
| `bash/`        | Shell config + `deps.sh` |
| `nvim/`        | Neovim config + `deps.sh` (self-contained; has its own Makefile and README) |
| `dev/`         | `deps.sh` for project runtimes |

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
├── Makefile                              Orchestrator: deps, install, shell, check, update
├── install.sh                            Symlink engine (backs up existing files)
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
