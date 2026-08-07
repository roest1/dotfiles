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
./tools/adopt.sh <cmd>  # print a deps.conf line, provider + package resolved
make test               # Lua unit tests (no plugins, no network)
```

`make check` asks "does this command exist." `make status` asks "is this machine
what the manifest says" — link targets and per-tool provenance. Prefer `status`
when the question is whether the repo is still telling the truth.

It does not report "installed but not declared". That list can't be computed
correctly — nothing distinguishes a dotfiles dependency from a project-scoped
tool — and suppressing it required naming unrelated projects in `deps.conf`.
The repo describes itself and nothing else; don't reintroduce an ignore list.

When adding a tool, add a `tool` line to the right section. **Don't add install logic** —
`lib/pkg.sh` holds the only implementation of "install a tool" (`pkg_install`,
`uv_install`, `mise_install`, `cargo_install`, `ensure_symlink`), and
`lib/providers.sh` dispatches to it. Every helper short-circuits on `command -v`, which is
what makes overlapping tools (`rg`, `fd` appear in both `[bash]` and `[nvim]`) safe.

There's also a `manual` provider. It installs nothing — it declares that an official
installer or an extracted build is an acceptable source, so `make status` doesn't flag a
correct state as drift (zoxide's curl installer, wezterm extracted into `~/.local`, bun's
own installer). The actual install goes in the section's `deps.sh`.

**Windows is a second entry point, not a second manifest.** `windows/install.ps1` parses
the same `deps.conf` from PowerShell, so the "nothing else enumerates links" rule still
holds across both. A section may declare `platform <linux|mac|windows>`, which makes it
invisible everywhere else.

The two parsers read that field with deliberately *opposite* defaults, and the asymmetry
is the whole point. A section with no `platform` line means "every platform this entry
point handles" — correct for `[bash]`, which really does run on Linux and macOS. The
PowerShell side instead requires `platform windows` explicitly, because inheriting the
permissive reading there would link `bashrc` into `%USERPROFILE%`. `[wezterm]` and
`[windows]` both claim `~/.config/wezterm/wezterm.lua` in their respective homes; the
filter is the only thing stopping a bare `./install.sh` inside WSL from overwriting the
Linux config with the Windows one. A `windows-latest` CI job asserts both halves.

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

Nix + home-manager genuinely solves provider resolution, pinning and provenance, and
Fedora packages it with `nix-daemon` split out so single-user needs no daemon. It was
deferred — and one of the three original reasons has since expired, which is worth
recording rather than leaving a stale justification standing.

**No longer true.** The strongest argument was that Mason kept the LSP layer imperative
regardless, so Nix would buy a reproducible `neovim`/`stylua`/`ripgrep` while six language
servers stayed mutable and still required node. **Mason is gone.** Every server is declared
now — `deps.conf` for the native ones, `nvim/lsp-servers/package.json` pinned in `bun.lock`
for the JS ones. That was the stated condition for revisiting, and it has been met.

**Still true.**

1. Steep learning curve on the repo that bootstraps every other machine. A half-understood
   Nix config fails on a fresh machine, which is the worst possible moment to find out.
2. `/nix` needs root — exactly the machine class `make link` exists for.

**Current honest assessment:** the gap Nix would close is much narrower than it was.
Versions are pinned in `bun.lock` and by mise, provenance is answerable through
`make status`, and nothing installs itself imperatively at editor startup any more. Nix
would still be stricter — a real closure rather than a manifest plus trust — but the
remaining delta is now smaller than the cost of switching.

The hedge stands: dependencies are *data*, so adopting Nix means writing a `nix` provider
in `lib/providers.sh`, not a rewrite.

## Footguns

- **`make` never reads `.bashrc`** (non-interactive, non-login), so the Makefile sets
  `PATH` explicitly to include `~/.local/bin`, `~/.local/share/mise/shims`, `~/.cargo/bin`
  and `~/.bun/bin`. Without it `make check` reports false MISSINGs. (It also still lists
  `~/.npm-global/bin`, which is vestigial — nothing installs there now that npm is gone.
  Harmless, since a missing directory on `PATH` costs nothing, but it can go with the
  `npm` provider whenever that's cleaned up.)
- **`EDITOR` is set unconditionally to `nvim`**, before `bash_local` is sourced. It
  cannot be `${EDITOR:-nvim}`: Fedora's `/etc/profile.d/nano-default-editor.sh` sets
  `EDITOR=/usr/bin/nano` first, so a `:-` default silently loses. Per-machine overrides go
  in `~/.bash_local`, sourced immediately after, which wins.
- **No node, npm or pip. Don't reintroduce them.** Mason was removed because it installs
  npm packages by shelling out to the `npm` binary, which only exists if node does. The six
  JS language servers — and `prettier` — now live in `nvim/lsp-servers/package.json`,
  installed by `bun` and run as `bun <path>`: servers via explicit `cmd` overrides in
  `lua/external/lsp_servers.lua`, prettier via the `formatters` block in
  `plugins/formatter.lua`.

  **Never add a `node` shim** — aliasing node to bun makes incompatibilities surface as
  errors blaming the wrong tool. That is not hypothetical any more: prettier's
  `--stdin-filepath` exits 0 and writes *nothing* under bun, while working correctly under
  node, which is why `formatter.lua` uses `--write` on a temp file instead. Behind a shim
  that would have presented as "formatting silently does nothing" with no clue where to
  look. Don't "tidy" it back to stdin.

  CI guards both: the manifest may not declare node/npm/pip, and no shim may exist. The JS
  server args are not uniform (`bash-language-server` wants `start`, not `--stdio`);
  `nvim/lsp-servers/verify.ts` proves each with a real LSP handshake.
- **`wezterm/wezterm.lua` is load-bearing beyond wezterm.** It declares the `mux` unix
  domain that the Jarvis sidecar connects to (`JARVIS_WEZTERM_DOMAIN` defaults to `'mux'`
  in `jarvis-ui/server/workerSession.ts`). Don't replace it with a stock config.

  `wezterm/wezterm-windows.lua` is a **different file for a different job**, not a variant
  to be merged back in. It configures `wezterm.exe` on the Windows host, whose purpose is
  to get you into WSL; it declares no `unix_domains`, because that socket path is a Linux
  path belonging to a process inside the guest.
- **`ln -s` run inside WSL onto `/mnt/c` produces a link Windows cannot follow.** It
  writes an *LX symlink*; Windows fails on it with `STATUS_IO_REPARSE_TAG_NOT_HANDLED`.
  Ordinary file *writes* to `/mnt/c` are fine — this is specific to symlinks. Nor will
  `wezterm.exe` load a config over `\\wsl.localhost\...`; the maintainer has said the WSL
  filesystem isn't visible to the host that way. Hence a second clone on `C:` and a
  PowerShell installer, rather than teaching `install.sh` to reach across.
- **`.ps1` files must be pure ASCII.** Windows PowerShell 5.1 reads a `.ps1` without a BOM
  as ANSI (cp1252), not UTF-8. An em dash (`E2 80 94`) decodes as three cp1252 characters
  ending in `0x94`, which in cp1252 is `"` — and PowerShell treats that as a **string
  delimiter**. A single em dash inside a *comment* opened a string that swallowed the rest
  of the file; the error it reported was a bogus "invalid variable reference" 200 lines
  away, in a comment that was never the problem. Don't chase the reported line — check for
  non-ASCII first. CI enforces this in the `shellcheck` job. A UTF-8 BOM would also work,
  but ASCII survives an editor stripping the BOM.
- **The PowerShell targets Windows PowerShell 5.1, not pwsh 7.** 5.1 is what a fresh box
  runs when the bootstrap line is pasted, so: no ternaries, no `??`, no `$IsWindows`,
  `Join-Path` takes exactly two arguments, and `$ErrorActionPreference = 'Stop'` does
  **not** catch a native command's failure — check `$LASTEXITCODE` after `winget` and
  `git`. `bootstrap.ps1` also keeps its whole body inside an invoked scriptblock, because
  a top-level `exit` under `irm | iex` terminates the user's shell. Nothing on Linux can
  parse any of this; the `windows` CI job is the only thing that checks it.

## Architecture

```
bash/
  bashrc                    Main entrypoint (~/.bashrc). OS detection, history,
                            shell options, PATH (dotnet, java, homebrew, cargo, mise,
                            bun), package managers, sources custom configs.
  bash_theme                Prompt (PS1 + right-aligned PROMPT_COMMAND), LS_COLORS,
                            conda env display, git branch/dirty/sync indicators,
                            GitHub Actions status in prompt (background-cached).
  bash_productivity         CLI tools: aliases (git, ls/cat/bat/eza), zoxide, fzf,
                            utility functions (mkcd, up, f, findword, lines, port,
                            serve, loop, extract, ddiff, c, etc.), .NET aliases
                            (dclean, dbuild, dtest), help system (`h`).
  bash_git                  GitHub Actions commands: gha, gha-fail, gha-open, gha-ui
                            (interactive workflow picker with smart log view;
                            scope: HEAD or recent runs).
  bash_github               Unified hub (gh-ui) + interactive GitHub management via fzf:
                            gpr (PR management with filters), ghsecrets, ghbranch, ghenv.
                            ghbranch drives RULESETS, not classic branch protection —
                            the classic API 404s on a ruleset-protected repo, which had
                            it calling main protected on one screen and unprotected on
                            the next. Reads /rules/branches/{b} (effective rules across
                            every ruleset); writes /rulesets/{id} with PUT, not PATCH.
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
  GITHUB_SETUP.md           Standing reference for new-repo settings and the
                            ruleset. Records what this repo's own config is and
                            why — keep it in step when those settings change.
nvim/lsp-servers/           JS language servers + prettier, installed by bun.
                            bun.lock is the source of truth; yarn.lock is
                            generated output that exists only so GitHub's
                            dependency graph can read the tree (it has no
                            bun.lock parser). CI asserts the two agree.
install.sh                  Symlinks all dotfiles into ~. Backs up existing files.
                            Generates bash_profile shim if missing. Safe to re-run.
bootstrap.ps1               Windows entry point: `irm ... | iex`. Clones to
                            %USERPROFILE%\dotfiles, hands off to windows/install.ps1.
windows/
  install.ps1               Reads the same deps.conf; links `platform windows`
                            sections and installs their `winget` tools.
  deps.ps1                  Platform fixups, the PowerShell analogue of a
                            section's deps.sh: 0xProto Nerd Font (per-user, no
                            admin), elevation-helper reporting.
  README.md                 Developer Mode, the CTRL+SHIFT+O picker, elevation,
                            and why the config can't be shared with WSL.
deps.conf                   THE MANIFEST — every link and dependency, one file.
lib/                        manifest.sh (parser), providers.sh (dispatch),
                            pkg.sh (installers), run.sh (section runner),
                            status.sh (declared-vs-actual drift).
Makefile                    Reads sections from deps.conf; install, link, check.
.github/workflows/ci.yml    Portability (link-only + install on 3 platforms) plus
                            the supply-chain jobs: bun audit, the Socket scan, and
                            the neovim floor / mise-fallback check.
README.md                   Setup instructions + file reference
CONTRIBUTING.md             How to add a tool without breaking the manifest
```

## Key Conventions

- **OS portability:** `_OS=mac|linux` detected in `bashrc`. Mac/Linux differences (homebrew paths, `date` flags, `stat` flags) are handled inline with conditionals.
- **Bash version:** macOS ships bash 3.2. `bash/deps.sh` installs bash 5 via homebrew. Bash 4+ features (`dirspell`, `globstar`) are guarded with `BASH_VERSINFO` checks.
- **Tool dependencies:** `zoxide`, `fzf`, `bat`, `eza`, `fd`, `ripgrep`, `gh`, `jq`. All optional — features degrade gracefully via `command -v` guards. Declared in `deps.conf`'s `[bash]` section, installed via brew/apt/dnf. Some tools have alternate binary names on RHEL/Debian (`bat` → `batcat`, `fd` → `fdfind`) — handled with fallback checks.
- **Symlink pattern:** `install.sh` symlinks `bash/*` to `~/.*` (e.g. `bash/bashrc` → `~/.bashrc`), driven entirely by the `link` lines in `deps.conf`. It hard-codes no filenames — adding or renaming a config file is a manifest edit and nothing else. Renames are safe because `install.sh` **prunes orphans**: a symlink pointing into this repo whose target no longer exists is removed, so the retired name can't survive next to the new one. That test is structural on purpose — don't replace it with a list of old names, which would need maintaining and would silently stop covering the next rename.
- **Navigation UX:** All interactive fzf commands use consistent keybindings — menus (`-`/`q` back), lists (type to filter, `esc` back), pagers (`r` refresh, `-`/`q` back).
- **Machine-local config:** `bash_local` holds per-machine setup (CUDA, nvim path, RHEL-specific exports) — gitignored, optional-sourced before other custom configs. `bash_password_commands` is gitignored for secrets. These two are the **only** configs not declared in `deps.conf`, and must stay that way: the manifest describes what every machine gets. They're symlinked by hand (`bashrc` sources `~/.bash_local`, not the repo path, so the file alone does nothing), and `prune_orphans` leaves them alone as long as their targets exist.

## When Editing

- Test on both bash 3.2 (macOS `/bin/bash`) and bash 5+ (homebrew / Linux).
- Guard all tool usage with `command -v` checks.
- Keep the `h` help function in `bash_productivity` in sync with any command changes.
- The README is intentionally concise: install + new-machine flow + GitHub tools pointer + "what goes where" table. Prose explanations of bash internals belong here in `CLAUDE.md`, not in the README.
