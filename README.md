# dotfiles

Personal configuration files. One clone, one script, full setup.

## Structure

```
~/.dotfiles/
├── install.sh                 Symlink everything into ~
├── .gitignore                 Keeps sensitive bash scripts out of git
├── README.md                  Setup instructions (you are here)
├── bash/
│   ├── bashrc                 → ~/.bashrc
│   ├── bash_roest_theme       → ~/.bash_roest_theme
│   ├── bash_roest_productivity → ~/.bash_roest_productivity
│   └── bash_roest_password_commands → ~/.bash_roest_password_commands (not tracked)
└── git/
│   ├── README.md              GitHub tips and tricks
    └── gitconfig              → ~/.gitconfig
```

Neovim config is a separate repo: [roest-nvim](https://github.com/roest1/roest-nvim)

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
| `bash/bash_roest_password_commands` | Sensitive commands (not tracked in git)                             |

## Password commands

Create `bash/bash_roest_password_commands` locally (gitignored):

```sh
touch ~/.dotfiles/bash/bash_roest_password_commands
```

This file is sourced by bashrc but never committed.
