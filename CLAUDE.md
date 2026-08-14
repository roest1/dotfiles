# CLAUDE.md

## Overview

Cross-platform dotfiles — terminal, editor and shell as one versioned unit. Installed personally on Linux Fedora, WSL Ubuntu, and SERHEL. Bash-based. Windows installation exists. A monorepo.

**macOS is CI-tested, not daily-driven.** Nobody runs this on a Mac, so the
support claim is exactly as strong as the `macos-latest` jobs — `link only
(macos)` and `install (macos / brew)` — and no stronger. That is a real claim,
not a hedge: those jobs link every `[bash]` config, install through brew, and
assert idempotence and orphan pruning. It is also a rule for changes here. Mac
behaviour that CI cannot exercise is unsupported, so prefer the portable
construct over the one that needs a Mac to verify — plain `readlink` over GNU
`readlink -f`, `sort -V` over anything BSD spells differently. If a Mac-only
path genuinely can't be covered, say so at the call site rather than implying
it works.

## Setup Workflow

```bash
curl -fsSL https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.sh | bash
# or, already cloned:
cd ~/dotfiles && make install
```

or see Makefile and install.sh

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

see `make help`

`make check` asks "does this command exist." `make status` asks "is this machine
what the manifest says" — link targets and per-tool provenance. Prefer `status`
when the question is whether the repo is still telling the truth.

It does not report "installed but not declared". That list can't be computed
correctly — nothing distinguishes a dotfiles dependency from a project-scoped
tool — and suppressing it required naming unrelated projects in `deps.conf`.
The repo describes itself and nothing else; don't reintroduce an ignore list.

It also does not report **duplicate** installs, and that one is a gap rather than a
principle. A `||` chain is satisfied by any member, so a tool installed by two providers
reads `✓` while PATH order alone decides which copy runs — and the dormant copy is
typically older than the pinned one. Unlike "installed but not declared", this *is*
computable: the tool is already in the manifest, so the question is only how many copies
of a declared tool exist. `mise prune` handles mise's own superseded versions; nothing
handles the cross-provider case. Evidence and the open design questions:
[`docs/decisions/tool-duplication.md`](docs/decisions/tool-duplication.md).

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

The two parsers read that field with deliberately _opposite_ defaults, and the asymmetry
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

Deferred. Dependencies are _data_, so adopting Nix means writing a `nix` provider in
`lib/providers.sh`, not a rewrite — that is the only part of the decision that changes how
you write code here. Reasoning, revisit conditions and current status:
[`docs/decisions/nix.md`](docs/decisions/nix.md).

## Footguns

- **`make` never reads `.bashrc`** (non-interactive, non-login), so the Makefile sets
  `PATH` explicitly to include `~/.local/bin`, `~/.local/share/mise/shims`, `~/.cargo/bin`
  and `~/.bun/bin`. Without it `make check` reports false MISSINGs.
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
  `--stdin-filepath` exits 0 and writes _nothing_ under bun, while working correctly under
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
  writes an _LX symlink_; Windows fails on it with `STATUS_IO_REPARSE_TAG_NOT_HANDLED`.
  Ordinary file _writes_ to `/mnt/c` are fine — this is specific to symlinks. Nor will
  `wezterm.exe` load a config over `\\wsl.localhost\...`; the maintainer has said the WSL
  filesystem isn't visible to the host that way. Hence a second clone on `C:` and a
  PowerShell installer, rather than teaching `install.sh` to reach across.
- **`.ps1` files must be pure ASCII.** Windows PowerShell 5.1 reads a `.ps1` without a BOM
  as ANSI (cp1252), not UTF-8. An em dash (`E2 80 94`) decodes as three cp1252 characters
  ending in `0x94`, which in cp1252 is `"` — and PowerShell treats that as a **string
  delimiter**. A single em dash inside a _comment_ opened a string that swallowed the rest
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

## Key Conventions

- **OS portability:** `_OS=mac|linux` detected in `bashrc`. Mac/Linux differences (homebrew paths, `date` flags, `stat` flags) are handled inline with conditionals.
- **Bash version:** `bash/deps.sh` installs bash 5 via homebrew. Bash 4+ features (`dirspell`, `globstar`) are guarded with `BASH_VERSINFO` checks.
- **Tool dependencies:** `zoxide`, `fzf`, `bat`, `eza`, `fd`, `ripgrep`, `gh`, `jq`. All optional — features degrade gracefully via `command -v` guards. Declared in `deps.conf`'s `[bash]` section, installed via brew/apt/dnf. Some tools have alternate binary names on RHEL/Debian (`bat` → `batcat`, `fd` → `fdfind`) — handled with fallback checks.
- **Symlink pattern:** `install.sh` symlinks `bash/*` to `~/.*` (e.g. `bash/bashrc` → `~/.bashrc`), driven entirely by the `link` lines in `deps.conf`. It hard-codes no filenames — adding or renaming a config file is a manifest edit and nothing else. Renames are safe because `install.sh` **prunes orphans**: a symlink pointing into this repo whose target no longer exists is removed, so the retired name can't survive next to the new one. That test is structural on purpose — don't replace it with a list of old names, which would need maintaining and would silently stop covering the next rename.
- **Navigation UX:** All interactive fzf commands use consistent keybindings — menus (`-`/`q` back), lists (type to filter, `esc` back), pagers (`r` refresh, `-`/`q` back). This is not a convention to remember: the menu contract lives in `__fzf_menu` (`bash/bash_productivity`), every screen calls it, and CI rejects a hand-rolled `fzf --disabled`. It used to be 18 copies of the same `--bind` string.
- **`h` is hand-maintained, and CI keeps it honest.** Adding, renaming or removing a command means editing `h` in the same commit. A CI step asserts both directions — every public function and alias is named in `h`, and every command in `h`'s quick reference actually resolves. Both had already drifted: `h` advertised `gh-tui` while the function was `gh-ui`, and kept a full help page for `lines` after it was deleted.
- **The `[bash]` file split is enforced, not conventional.** `bash_git` (git porcelain) → `bash_github` (plain `gh` + shared helpers) → `bash_github_tui` (everything interactive), sourced in that order. Only the TUI file may invoke fzf, and CI checks it — that boundary is what keeps the interactive layer replaceable as a unit. It is currently working and parked; see [`docs/decisions/github-tui.md`](docs/decisions/github-tui.md) for the plan and the open question that gates it.
- **`mise.toml` and `mise.lock` are generated.** `deps.conf` is still the only place tools are declared; `tools/gen-mise.sh` derives the mise-provided subset from it and `mise lock` adds per-platform checksums. Run `make mise-lock` after touching a mise tool. Don't hand-edit the tool list (versions are fine to edit — regenerating preserves them).
- **Machine-local config:** `~/.bash_local` (per-machine paths and exports) and `~/.bash_password_commands` (secrets) are optional-sourced by `bashrc`. They live **in `$HOME`, never in the work tree** — do not "tidy" them back into `bash/` with a `.gitignore` entry, which is how they used to be. Outside the tree, git cannot see them; inside it, protection is a rule that `git add -f` overrides and that a `.gitignore` rewrite silently deletes. They're also the only configs not declared in `deps.conf`, and must stay that way: the manifest describes what _every_ machine gets.

## When Editing

- Test on both bash 3.2 (macOS `/bin/bash`) and bash 5+ (homebrew / Linux).
- Guard all tool usage with `command -v` checks.
- Keep the `h` help function in `bash_productivity` in sync with any command changes.
- The README is intentionally concise: install + new-machine flow + GitHub tools pointer + "what goes where" table. Prose explanations of bash internals belong here in `CLAUDE.md`, not in the README.
