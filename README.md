# dotfiles

Personal configuration files. One clone, one script, full setup.

## Structure

```
~/dotfiles/
├── Makefile                    Orchestrator: deps, install, shell, check, update
├── install.sh                  Symlink everything into ~
├── README.md                   Setup instructions (you are here)
├── CLAUDE.md                   AI assistant project instructions
├── bash/
│   ├── bashrc                  → ~/.bashrc (main entrypoint)
│   ├── bash_roest_theme        → ~/.bash_roest_theme
│   ├── bash_roest_productivity → ~/.bash_roest_productivity (core commands)
│   ├── bash_roest_git          → ~/.bash_roest_git (GitHub Actions tools)
│   ├── bash_roest_github       → ~/.bash_roest_github (interactive GitHub screens)
│   ├── bash_roest_local        → ~/.bash_roest_local (machine-specific, not tracked)
│   └── bash_roest_password_commands → ~/.bash_roest_password_commands (not tracked)
└── git/
    ├── README.md               GitHub tips and tricks
    ├── GITHUB_TOOLS.md         Interactive tools walkthrough + demos
    └── gitconfig               → ~/.gitconfig
```

Neovim config is a separate repo: [roest-nvim](https://github.com/roest1/roest-nvim)

**[GitHub Terminal Tools Guide →](git/GITHUB_TOOLS.md)** — Full walkthrough with demos of `gpr`, `ghsecrets`, `ghbranch`, `ghenv`, and `gha-ui`.

## Install

```sh
git clone https://github.com/roest1/dotfiles.git ~/dotfiles
cd ~/dotfiles
make all
```

`make all` runs three steps:

1. **`make deps`** — installs CLI tools (brew on macOS/WSL, dnf on RHEL)
2. **`make install`** — symlinks dotfiles into `$HOME`, backs up existing files to `~/.dotfiles_backup/`
3. **`make check`** — verifies all tools are available

Other targets: `make shell` (set default shell to bash), `make update` (git pull + re-install).

All targets are idempotent — safe to re-run.

> **NOTE:** filenames in `bash/` and `git/` are hard-coded in `install.sh`.
> Edit the install script if you add or rename files.

## New machine setup

```sh
# 1. Dotfiles
git clone https://github.com/roest1/dotfiles.git ~/dotfiles
cd ~/dotfiles && make all

# 2. Neovim config
git clone https://github.com/roest1/roest-nvim.git ~/.config/nvim
cd ~/.config/nvim && chmod +x bootstrap.sh && ./bootstrap.sh

# 3. Restart shell
exec bash
```

## What goes where

| File                                | Controls                                                            |
| ----------------------------------- | ------------------------------------------------------------------- |
| `bash/bashrc`                       | Shell options, PATH, package managers, sources theme + productivity |
| `bash/bash_roest_theme`             | Prompt, colors, LS_COLORS, man page colors                          |
| `bash/bash_roest_productivity`      | Custom commands, aliases, help system                               |
| `bash/bash_roest_git`               | GitHub Actions commands (gha, gha-ui, gha-fail, gha-open)           |
| `bash/bash_roest_github`            | Interactive GitHub screens (gpr, ghsecrets, ghbranch, ghenv)        |
| `bash/bash_roest_local`             | Machine-specific config — CUDA, nvim path, etc. (not tracked)      |
| `bash/bash_roest_password_commands` | Sensitive commands (not tracked in git)                             |
| `git/GITHUB_TOOLS.md`               | Walkthrough + demo recordings for all GitHub tools                  |

## Machine-local config

Create `bash/bash_roest_local` on each machine for host-specific setup (gitignored):

```sh
touch ~/dotfiles/bash/bash_roest_local
```

This is sourced by bashrc but never committed. Use it for things like CUDA paths,
custom nvim installs, RHEL-specific exports, etc.

## Password commands

Create `bash/bash_roest_password_commands` locally (gitignored):

```sh
touch ~/dotfiles/bash/bash_roest_password_commands
```

This file is sourced by bashrc but never committed.
