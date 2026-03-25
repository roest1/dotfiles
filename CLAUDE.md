# dotfiles

Riley Oest's cross-platform dotfiles (macOS + Linux/WSL + RHEL). Bash-based.

## Setup workflow

```bash
git clone https://github.com/roest1/dotfiles.git ~/dotfiles
cd ~/dotfiles
make all        # install deps, symlink dotfiles, verify tools
```

Individual targets: `make deps`, `make install`, `make shell`, `make check`, `make update`.

`install.sh` is the core symlinking engine — the Makefile wraps it. Both are needed.

## Repo structure

```
bash/
  bashrc                    # Main entrypoint (~/.bashrc). OS detection, history,
                            #   shell options, PATH, package managers, sources custom configs.
  bash_profile              # Login shell shim — just sources .bashrc (all platforms)
  bash_roest_theme          # Prompt (PS1 + right-aligned PROMPT_COMMAND), LS_COLORS,
                            #   conda env display, git branch/dirty/sync indicators,
                            #   GitHub Actions status in prompt (background-cached).
  bash_roest_productivity   # CLI tools: aliases (git, ls/cat/bat/eza), zoxide, fzf,
                            #   utility functions (mkcd, up, f, findword, lines, port,
                            #   serve, loop, extract, etc.), help system (`h`).
  bash_roest_git            # GitHub Actions commands: gha, gha-fail, gha-open, gha-ui
                            #   (interactive workflow picker with smart log view).
  bash_roest_github         # Interactive GitHub management via fzf: gpr (PR management),
                            #   ghsecrets, ghbranch, ghenv.
git/
  gitconfig                 # Global git config (user, credential, lfs)
install.sh                  # Symlinks all dotfiles into ~. Backs up existing files.
                            #   Creates bash_profile shim on macOS. Safe to re-run.
Makefile                    # Orchestrator: deps (brew/dnf), install, shell, check, update.
```

## Key conventions

- **OS portability**: `_OS=mac|linux` detected in bashrc. Mac/Linux differences are
  handled inline with conditionals (homebrew paths, date flags, stat flags, etc.).
- **Bash version**: macOS ships bash 3.2. `make deps` installs bash 5 via homebrew.
  Bash 4+ features (dirspell, globstar) are guarded with `BASH_VERSINFO` checks.
- **Tool dependencies**: zoxide, fzf, bat, eza, fd, ripgrep, gh, jq. All optional —
  features degrade gracefully via `command -v` guards. `make deps` installs via
  brew (macOS/WSL) or dnf+EPEL (RHEL). Some tools (bat→batcat, fd→fdfind) have
  alternate binary names on RHEL/Debian — all handled with fallback checks.
- **Symlink pattern**: `install.sh` symlinks `bash/*` to `~/.*` (e.g., `bash/bashrc` -> `~/.bashrc`).
- **Navigation UX**: All interactive fzf commands use consistent keybindings:
  menus (`-/q` back), lists (type to filter, `esc` back), pagers (`r` refresh, `-/q` back).
- **Machine-local config**: `bash_roest_local` holds per-machine setup (CUDA, nvim path,
  RHEL-specific exports, etc.) — gitignored, optional-sourced before other custom configs.
  `bash_roest_password_commands` is also gitignored for secrets.

## When editing

- Test changes work on both bash 3.2 (macOS /bin/bash) and bash 5+ (homebrew / Linux).
- All tool usage should be guarded with `command -v` checks.
- Keep the `h` help function in `bash_roest_productivity` in sync with any command changes.
