# dotfiles

Personal configuration files. One clone, one script, full setup. Cross-platform bash (macOS + Linux/WSL + RHEL).

## Install

| Step | Command |
| ---- | ------- |
| 1. Clone          | `git clone https://github.com/roest1/dotfiles.git ~/dotfiles` |
| 2. Run everything | `cd ~/dotfiles && make all` |
| 3. Restart shell  | `exec bash` |

`make all` runs three idempotent steps: `make deps` (brew/dnf installs CLI tools) → `make install` (symlinks `bash/*` and `git/gitconfig` into `~`, backs up existing files to `~/.dotfiles_backup/`) → `make check` (verifies tools).

**Other targets:** `make shell` (set default shell to bash), `make update` (git pull + reinstall).

**Tools installed:** zoxide, fzf, bat, eza, fd, ripgrep, gh, jq, plus bash 5 on macOS (ships 3.2).

## New machine setup

```sh
# 1. Dotfiles
git clone https://github.com/roest1/dotfiles.git ~/dotfiles
cd ~/dotfiles && make all

# 2. Neovim config
git clone https://github.com/roest1/roest-nvim.git ~/.config/nvim
cd ~/.config/nvim && make all

# 3. Restart shell
exec bash
```

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
└── git/
    ├── gitconfig                       → ~/.gitconfig
    ├── README.md                         GitHub tips and tricks
    └── GITHUB_TOOLS.md                   Interactive tools walkthrough
```
</details>

Neovim config lives in a separate repo: [roest-nvim](https://github.com/roest1/roest-nvim).

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

## Machine-local config

Create either file for host-specific setup. Both are gitignored and sourced by `bashrc`:

```sh
touch ~/dotfiles/bash/bash_roest_local              # CUDA paths, per-machine exports
touch ~/dotfiles/bash/bash_roest_password_commands  # secrets
```

> **Note:** filenames in `bash/` and `git/` are hard-coded in `install.sh`. Edit the script if you add or rename files.

## License

MIT
