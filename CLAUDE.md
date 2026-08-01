# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

Riley Oest's cross-platform dotfiles (macOS + Linux/WSL + RHEL). Bash-based. A monorepo: the neovim config lives in `nvim/`, merged in from the former `roest1/nvim` repo with full history.

## Setup Workflow

```bash
curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
# or, already cloned:
cd ~/dotfiles && make install
```

## `deps.conf` is the source of truth

Every config symlink and every dependency is declared in `deps.conf`. Nothing else
enumerates them — the `Makefile` reads sections from the manifest and does not know what a
"bash" or an "nvim" is.

**Adding a program = a new section plus its config file.** No Makefile, install.sh, or
bootstrap.sh edits. If you find yourself editing those to add a tool, you're doing it wrong.

**Toggling is commenting.** There is no `WITHOUT=` flag, no profiles, no "areas" — that
abstraction was removed deliberately because it earned nothing over a section header named
after the program. To skip a tool, comment its line; to skip a program, don't pass its
section.

```
make install            # everything enabled
make install nvim       # one section
make link               # symlinks only: no sudo, no network
make check              # verify enabled tools are present
make status             # sync status: declared vs. actual (drift detection)
```

`make check` asks "does this command exist." `make status` asks "is this machine
what the manifest says" — link targets, per-tool provenance, and orphans. Prefer
`status` when the question is whether the repo is still telling the truth.

When adding a tool, add a `tool` line to the right section. **Don't add install logic** —
`lib/pkg.sh` holds the only implementation of "install a tool" (`pkg_install`,
`npm_install`, `uv_install`, `mise_install`, `cargo_install`, `ensure_symlink`), and
`lib/providers.sh` dispatches to it. Every helper short-circuits on `command -v`, which is
what makes overlapping tools (`rg`, `fd` appear in both `[bash]` and `[nvim]`) safe.

There's also a `manual` provider. It installs nothing — it declares that an official
installer or an extracted build is an acceptable source, so `make status` doesn't flag a
correct state as drift (zoxide's curl installer, wezterm extracted into `~/.local`, bun's
own installer). The actual install goes in the section's `deps.sh`.

Prefer `pkg` for anything the distro ships; `mise` for tools distros don't reliably carry;
`||` chains rather than conditionals. **Never key provider choice on `$PM`** — that's a
proxy for facts it can't see. The old code ran `cargo_install tree-sitter` whenever
`$PM = dnf`, citing RHEL 9's glibc 2.35, and so burned minutes compiling on Fedora 44,
which ships `tree-sitter-cli` and glibc 2.43. Write `pkg||cargo` instead.

Genuinely conditional platform logic (apt's `fdfind`/`batcat` names, dnf's `clang-devel`
for bindgen, WSL clipboard probing) belongs in an optional `<section>/deps.sh`, which
`lib/run.sh` runs after that section's tools. Declarative for the common case, script for
the rest — don't force an `if` into the manifest.

### Why not Nix

Asked and answered — record, so it isn't relitigated by accident. Nix + home-manager
genuinely solves provider resolution, pinning and provenance, and Fedora packages it with
`nix-daemon` split out so single-user needs no daemon. It was deferred because:

1. **Mason keeps the LSP layer imperative regardless.** Six of eight language servers are
   installed by Mason at runtime via npm. Nix would give reproducible neovim/stylua/ripgrep
   while the LSP layer stayed mutable and still needed node — most of the learning curve
   for part of the benefit.
2. Steep learning curve on the repo that bootstraps every other machine.
3. `/nix` needs root — exactly the machine class the toggles exist for.

**What would change the answer:** dropping Mason for nix-managed LSPs. At that point full
reproducibility is actually reachable. The hedge is already in place — dependencies are
*data* in `deps.conf`, so adopting Nix means writing a `nix` provider in
`lib/providers.sh`, not a rewrite.

## Footguns

- **`make` never reads `.bashrc`** (non-interactive, non-login), so the Makefile sets
  `PATH` explicitly to include `~/.local/bin`, `~/.local/share/mise/shims`, `~/.cargo/bin`,
  `~/.bun/bin`, and `~/.npm-global/bin`. Without it `make check` reports false MISSINGs.
- **`EDITOR` is set unconditionally to `nvim`**, before `bash_roest_local` is sourced. It
  cannot be `${EDITOR:-nvim}`: Fedora's `/etc/profile.d/nano-default-editor.sh` sets
  `EDITOR=/usr/bin/nano` first, so a `:-` default silently loses. Per-machine overrides go
  in `~/.bash_roest_local`, sourced immediately after, which wins.
- **node cannot be swapped for bun.** Mason shells out to `npm` specifically, and the six
  JS language servers need a JS runtime to execute. `lsp.lua` drops them when `node` is
  absent so the editor degrades instead of erroring — keep that gate if you touch the
  servers table, and CI asserts it.
- **`wezterm/wezterm.lua` is load-bearing beyond wezterm.** It declares the `mux` unix
  domain that the Jarvis sidecar connects to (`JARVIS_WEZTERM_DOMAIN` defaults to `'mux'`
  in `jarvis-ui/server/workerSession.ts`). Don't replace it with a stock config.

## Architecture

```
bash/
  bashrc                    Main entrypoint (~/.bashrc). OS detection, history,
                            shell options, PATH (dotnet, java, homebrew, cargo, mise,
                            bun), package managers, sources custom configs.
  bash_roest_theme          Prompt (PS1 + right-aligned PROMPT_COMMAND), LS_COLORS,
                            conda env display, git branch/dirty/sync indicators,
                            GitHub Actions status in prompt (background-cached).
  bash_roest_productivity   CLI tools: aliases (git, ls/cat/bat/eza), zoxide, fzf,
                            utility functions (mkcd, up, f, findword, lines, port,
                            serve, loop, extract, ddiff, c, etc.), .NET aliases
                            (dclean, dbuild, dtest), help system (`h`).
  bash_roest_git            GitHub Actions commands: gha, gha-fail, gha-open, gha-ui
                            (interactive workflow picker with smart log view;
                            scope: HEAD or recent runs).
  bash_roest_github         Unified hub (gh-ui) + interactive GitHub management via fzf:
                            gpr (PR management with filters), ghsecrets, ghbranch, ghenv.
  bash_profile              Login-shell shim — generated by install.sh if missing,
                            just sources .bashrc. Tracked — keep it a pure shim.
                            Tool installers (rustup, bun) append PATH lines here
                            through the ~ symlink, showing up as uncommitted changes
                            in this repo; move them to the package-manager section
                            of bashrc (guarded) so non-login shells get them too.
git/
  gitconfig                 Global git config (user, credential, lfs)
  README.md                 GitHub tips and tricks reference
  GITHUB_TOOLS.md           Interactive tools walkthrough + demo recording guide
install.sh                  Symlinks all dotfiles into ~. Backs up existing files.
                            Generates bash_profile shim if missing. Safe to re-run.
deps.conf                   THE MANIFEST — every link and dependency, one file.
lib/                        manifest.sh (parser), providers.sh (dispatch),
                            pkg.sh (installers), run.sh (section runner).
Makefile                    Reads sections from deps.conf; install, link, check.
README.md                   Setup instructions + file reference
```

## Key Conventions

- **OS portability:** `_OS=mac|linux` detected in `bashrc`. Mac/Linux differences (homebrew paths, `date` flags, `stat` flags) are handled inline with conditionals.
- **Bash version:** macOS ships bash 3.2. `bash/deps.sh` installs bash 5 via homebrew. Bash 4+ features (`dirspell`, `globstar`) are guarded with `BASH_VERSINFO` checks.
- **Tool dependencies:** `zoxide`, `fzf`, `bat`, `eza`, `fd`, `ripgrep`, `gh`, `jq`. All optional — features degrade gracefully via `command -v` guards. Declared in `deps.conf`'s `[bash]` section, installed via brew/apt/dnf. Some tools have alternate binary names on RHEL/Debian (`bat` → `batcat`, `fd` → `fdfind`) — handled with fallback checks.
- **Symlink pattern:** `install.sh` symlinks `bash/*` to `~/.*` (e.g. `bash/bashrc` → `~/.bashrc`). Filenames are hard-coded in `install.sh` — edit it when adding or renaming files.
- **Navigation UX:** All interactive fzf commands use consistent keybindings — menus (`-`/`q` back), lists (type to filter, `esc` back), pagers (`r` refresh, `-`/`q` back).
- **Machine-local config:** `bash_roest_local` holds per-machine setup (CUDA, nvim path, RHEL-specific exports) — gitignored, optional-sourced before other custom configs. `bash_roest_password_commands` is gitignored for secrets.

## When Editing

- Test on both bash 3.2 (macOS `/bin/bash`) and bash 5+ (homebrew / Linux).
- Guard all tool usage with `command -v` checks.
- Keep the `h` help function in `bash_roest_productivity` in sync with any command changes.
- The README is intentionally concise: install + new-machine flow + GitHub tools pointer + "what goes where" table. Prose explanations of bash internals belong here in `CLAUDE.md`, not in the README.
