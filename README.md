# dotfiles

Personal configuration files. One clone, one script, full setup.

## Structure

```
~/.dotfiles/
├── install.sh                  Symlink everything into ~
├── .gitignore                  Keeps sensitive bash scripts out of git
├── README.md                   Setup instructions (you are here)
├── bash/
│   ├── bashrc                  → ~/.bashrc (source)
│   ├── bash_roest_theme        → ~/.bash_roest_theme
│   ├── bash_roest_productivity → ~/.bash_roest_productivity (core commands)
│   ├── bash_roest_git          → ~/.bash_roest_git (git tools and commands)
│   ├── bash_roest_github       → ~/.bash_roest_github (interactive GitHub screens)
│   └── bash_roest_password_commands → ~/.bash_roest_password_commands (not tracked)
└── git/
│   ├── README.md              GitHub tips and tricks
│   ├── GITHUB_TOOLS.md        Interactive tools walkthrough + demos
    └── gitconfig              → ~/.gitconfig
```

Neovim config is a separate repo: [roest-nvim](https://github.com/roest1/roest-nvim)

**[GitHub Terminal Tools Guide →](git/GITHUB_TOOLS.md)** — Full walkthrough with demos of `gpr`, `ghsecrets`, `ghbranch`, `ghenv`, and `gha-ui`.

## Install

```sh
git clone https://github.com/roest1/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
chmod +x install.sh
./install.sh
```

The install script:

- Symlinks files into `$HOME`
- Backs up any existing files to `~/.dotfiles_backup/`
- Safe to re-run (skips already-correct symlinks)

> **NOTE:** filenames in `bash/` and `git/` are hard-coded in `install.sh`.
>
> You must edit the install script manually if you are changing or adding any files to these directories
> or else they will not install correctly.

## New machine setup

```sh
# 1. Dotfiles
git clone https://github.com/roest1/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh

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
| `bash/bash_roest_password_commands` | Sensitive commands (not tracked in git)                             |
| `git/GITHUB_TOOLS.md`               | Walkthrough + demo recordings for all GitHub tools                  |

## Password commands

Create `bash/bash_roest_password_commands` locally (gitignored):

```sh
touch ~/.dotfiles/bash/bash_roest_password_commands
```

This file is sourced by bashrc but never committed.
