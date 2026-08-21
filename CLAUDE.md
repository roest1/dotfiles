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
after the program. To skip a tool, comment its line.

**To skip a whole section on ONE machine, that comment goes in
`~/.config/dotfiles/sections`, not in `deps.conf`.** Commenting a line here is a tracked
edit, so a machine-local preference would become a diff you carry forever or commit by
accident — the same argument that keeps `~/.bash_local` out of the work tree. Seed it with
`make sections > ~/.config/dotfiles/sections` and comment what this machine does not want.

Absent — every fresh machine — means every section, so the catalogue stays the default and
the file only ever narrows it. Naming a section explicitly always wins: `make install
claude` installs it whether or not this machine opted in, which is what makes the file a
preference rather than a wall. A name that is not a real section warns on stderr rather
than silently installing nothing. A file with *everything* commented out refuses rather
than falling through to "no arguments means all", which is the one way this could have
quietly done the opposite of what it was told.

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

**Windows is the one exception to "`deps.conf` is the source of truth", and it is
deliberate.** `windows/install.ps1` declares its payload in two tables at the top of the
file — `$Links` and `$WingetTools` — and reads no manifest at all. Adding a Windows
config is an edit to that script, not to `deps.conf`.

That is a reversal, so the reasoning matters. The script used to parse `deps.conf` in
PowerShell to keep the "nothing else enumerates links" rule true across both entry
points. It cost ~130 lines of comment-stripping and two-pass section reading to describe
**one symlink and one winget package**, and it forced a `platform` mechanism into
`lib/manifest.sh` whose only job was arbitrating between the two — `[wezterm]` and
`[windows]` both named `~/.config/wezterm/wezterm.lua`, so without a filter a bare
`./install.sh` inside WSL overwrote the Linux config with the Windows one.

The parity was never real either: the two parsers read `platform` with deliberately
_opposite_ defaults, because a shared reading would have linked `bashrc` into
`%USERPROFILE%`. Declaring the payload where the Windows installer can read it directly
retired the second parser, the `platform` mechanism and the conflict in one move. **There
is no `platform` line type and no `winget` provider** — CI rejects both.

What survives is the part that was doing real work: idempotent linking, stale-link
detection, backup-before-replace, and the symlink→copy fallback with Developer Mode
guidance. A `windows-latest` CI job still asserts the config lands, matches the repo,
re-runs idempotently, and touches no Linux destination — that last one because `$Links`
is hand-written now, so a Linux path pasted into it would otherwise install unopposed.

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

- **`make` output is rendered in Science Gothic Mono, and the carrier is `SGR 6`.**
  `lib/sgr.sh` is the only thing that emits it, and every escape it defines is empty
  unless **all three** of `[ -t 1 ]`, `TERM_PROGRAM=WezTerm`, and a linked
  `~/.config/wezterm/fonts` hold. That guard is not belt-and-braces; each condition is a
  different failure. Without the tty half, escapes reach a pipe — and CI itself greps
  `make check bash | tee`. Without the WezTerm half, SGR 6 means what it actually says on
  every other terminal: **rapid blink**, over ssh, in GNOME Terminal, on a Mac. And being
  *in* WezTerm still isn't enough, because WezTerm only honours the attribute if this
  repo's config is the live one — on a machine that hasn't run `make link`, or one
  pointed at a stock config, it blinks again. The linked font directory is the cheapest
  true proxy for that, since `deps.conf` links config and fonts together. All three
  directions are asserted in the `manifest` CI job, because none of them is visible to
  whoever writes the code — they're always in WezTerm, always on a tty, always linked.

  Italic looks like the obvious carrier and is wrong: rose-pine italicises nvim's
  comments, so the whole editor would silently change font.

  The font is **generated, not downloaded** — `wezterm/mkmono.py` (PEP 723, run by `make
  mono-font`, same arrangement as `mise.toml`) derives a monospaced cut from upstream's
  variable Science Gothic, and the two `.ttf` files it writes are committed under
  `wezterm/fonts/`. A fresh machine builds nothing. It exists because a terminal is a
  fixed grid and Science Gothic is proportional: its `m` wants 0.99em against a 0.62em
  cell while its `l` wants 0.30em, so raw Science Gothic collides and gaps. It works in
  the tab bar only because that is proportional text laid out proportionally.

  **The fonts are read via `font_dirs`, never installed into the system font path.**
  `deps.conf` links `wezterm/fonts` → `~/.config/wezterm/fonts` and both configs say
  `wezterm.config_dir .. "/fonts"`. That is what makes this portable in one line each:
  no `fc-cache` (which macOS hasn't got), no `~/Library/Fonts` vs `~/.local/share/fonts`
  split, and — the real reason — no chance of a stale copy elsewhere shadowing it. Two
  files claiming family `Science Gothic Mono` style `Regular` resolve by first match,
  and the loser is silently the wrong glyphs. That already happened once during
  development and cost an afternoon.

  `wezterm-windows.lua` needs the same rules, and it is easy to talk yourself out of:
  `make` runs in the WSL guest, but the guest only writes the escape — `wezterm.exe` on
  the host draws it.

  **The two `.ttf` files are OFL, not MIT, and `LICENSE` carves them out explicitly.**
  That is required, not tidy: OFL 1.1 §5 says the font must be distributed *entirely*
  under the OFL and under no other licence, so a repo-wide MIT grant would conflict.
  `wezterm/fonts/OFL.txt` is the standalone copy, and `mkmono.py` deliberately preserves
  name IDs 0/13/14 (upstream copyright and licence) — don't "clean up" those fields.
  Upstream declares **no** Reserved Font Name, which is the only OFL clause that would
  have restricted the derivative's name, so `Science Gothic Mono` is permissible. CI
  asserts both the licence file and the carve-out survive.

- **Inside WSL, `[wezterm]` installs no wezterm and no fonts — deliberately.** WSL passes
  every test the rest of the repo makes (uname says Linux, `$PM` is apt) and the terminal
  is still not in there: `wezterm.exe` runs on the host and draws the pixels, the guest
  only writes escape sequences into it. So a wezterm installed in the guest is a GUI
  nothing launches, and fonts installed into the guest's fontconfig are glyphs nothing
  renders — both have to exist on the *Windows* side, which is what `windows/deps.ps1`
  and the `wezterm\fonts` entry in `windows/install.ps1` are for.

  `tool_applies_here` in `lib/pkg.sh` is the whole mechanism, consulted by `run_tools`,
  `run_check` and `status_tools`. It names one tool outside `deps.conf`, which is a real
  cost — but the alternative was a section-applicability line in the manifest, i.e. the
  `platform` mechanism that was deliberately deleted, reintroduced as a line type, a
  parser change and a CI rule to describe a single tool. `run_check` already special-cases
  `bat`/`batcat` and `fd`/`fdfind`, so this is the shape that file was already in.

  **The links are NOT skipped, and that is the part to not "tidy".** `wezterm.lua`
  declares the `mux` unix domain on a socket path under `$XDG_RUNTIME_DIR` — a *guest*
  path, belonging to a process inside WSL — so a `wezterm-mux-server` running in there
  reads it. Only the binary and the font downloads drop out. No CI runner is WSL, so both
  directions of the predicate are asserted in the `manifest` job by overriding `is_wsl`:
  under WSL it must suppress wezterm and **nothing else**, and on a plain Linux box it
  must suppress nothing, or wezterm silently stops installing everywhere.

- **`pkg_install` asks `apt-cache` before it asks `sudo`.** `sudo apt install wezterm` on
  a distro with no such package still prompts for a password *first* and only then says
  `Unable to locate package` — so a package apt was never going to provide costs an
  interactive stop in the middle of an otherwise unattended install. The probe reads the
  local lists, so it needs no network. It is **apt-only on purpose**: dnf's equivalent
  either hits the network or trusts a cache that may be empty, and a false "no such
  package" there would silently skip a package that does exist, which is worse than the
  prompt this avoids.

- **The blink attribute is now fully spent — both halves.** SGR 6 is Science Gothic
  Mono, above; **SGR 5** (slow blink, `text_blink_rate = 0`) is the file you are editing
  in nvim, written by `nvim/lua/external/altfont.lua` and read by the same `font_rules`.
  There is no third carrier and there is not going to be one: everything else wezterm can
  match a font on — intensity, italic, underline, reverse, strikethrough — *means*
  something on screen, and blink was only available because the rate can be set to zero.
  So do not reach for a blink attribute for anything else, and do not assume an SGR 5 in
  a capture is a bug.

  The same three-condition guard applies, for the same reason: outside WezTerm SGR 5 is
  blinking text, so `altfont.lua` refuses unless `TERM_PROGRAM=WezTerm` **and** the fonts
  are linked. `wezterm-windows.lua` needs these rules too — nvim runs in the WSL guest,
  but `wezterm.exe` on the host draws what it emits.

  The four lanes are `shell`, `nvim.ui`, `nvim.editor` and `claude`. `nvim.ui` is NOT
  "oil" — oil is the most visible thing it draws, but the lane is the window's base font
  while nvim holds focus, so it is also telescope, the statusline, the gutter and every
  float.

  Which font each lane gets is picked by `font` (a Rust TUI, `tui/font`) and written to
  `~/.config/wezterm/fonts.conf` — machine-local, not linked, not in `deps.conf`, same
  footing as `~/.bash_local`. Details live next to the code: `wezterm/wezterm.lua` for the
  lanes, [`nvim/CLAUDE.md`](nvim/CLAUDE.md) for the writer, [`tui/CLAUDE.md`](tui/CLAUDE.md)
  for the picker.

- **`tui/` is a Rust workspace, and it is the repo's first compile-at-install.**
  `deps.conf`'s `[tui]` declares its binaries `manual`, never `cargo`: the cargo
  provider installs by crate NAME from crates.io, and `font` is a name someone
  else owns there — it would fetch a stranger's crate and report success. The
  real install is `cargo install --path` in `tui/deps.sh`.

  cargo is REQUIRED by this section, not preferred, and it fails loudly rather
  than skipping: these binaries are built from the tree, so there is no route to
  them without a toolchain. `tui/deps.sh` calls `ensure_cargo` in `lib/pkg.sh`,
  which installs rustup when it has to — the same curl-piped route `uv`, `mise`
  and `zoxide` already take, kept in the one file allowed to hold it.

  That is affordable only because opting out is durable: leave `tui` out of
  `~/.config/dotfiles/sections` and the section is never swept. An offline
  machine does not select it and `make install bash nvim` is unaffected.

  A bash function may never be named after one of these binaries; a function
  wins over PATH, so a `font()` would silently shadow it. CI asserts both.
  Details next to the code: [`tui/CLAUDE.md`](tui/CLAUDE.md).

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

- **Developer Mode being ON does not make `New-Item -ItemType SymbolicLink` work under
  Windows PowerShell 5.1.** It fails with `NewItemSymbolicLinkElevationRequired` —
  *"Administrator privilege required for this operation"* — because 5.1's implementation
  never passes `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`. PowerShell 7's does, which
  is exactly why this is easy to miss: it works when you test it in pwsh and fails for
  every user who pastes the bootstrap line into the shell a fresh box actually opens.

  `cmd`'s `mklink` **does** pass the flag, and has since Windows 10 1703. Measured on
  Windows 11 24H2 (build 26100.9168), Developer Mode on, unelevated, same shell:
  `New-Item` denied, `mklink` succeeded for both a file and a `/D` directory. So
  `Install-ConfigLink` tries `New-Item`, then `mklink`, and only then copies.

  Don't "tidy" the second attempt away as redundant — without it the installer silently
  degrades to copies on the default Windows shell, and a copy stops tracking the repo
  while still looking like a successful install. Pass each path as its own argument
  rather than building one command string: the destination is under `%USERPROFILE%`,
  which routinely contains a space.

- **`winget install` reports "already installed, nothing to upgrade" as a failure.** Exit
  `0x8A15002B` / `-1978335189` (`APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE`) is the
  state `Install-WingetTool` is *trying to reach*, not an error. It surfaces on any re-run
  where the shell's `PATH` predates the install: `Get-Command wezterm` misses it, winget is
  asked to install again, and answers that it is already current — so a correctly
  configured machine printed `FAILED wezterm` and `1 item(s) failed`.

  The fix is the rule `lib/providers.sh` already states — *trust the tool, not the
  installer's exit code*. `Install-WingetTool` rebuilds `$env:Path` from the registry
  (same idiom `bootstrap.ps1` uses after installing git) and checks `Get-Command` before
  it looks at `$LASTEXITCODE` at all, with the specific exit code as a second chance for
  packages whose binary this shell still cannot see. Don't reduce it back to a bare
  `if ($LASTEXITCODE -ne 0)`.

- **`sudo.exe` ships in `System32` on Windows 11 24H2+ whether or not the feature is
  enabled**, so `Test-Path` on the binary answers "did Microsoft ship it", not "will it
  run". `windows/deps.ps1` reported `ok sudo` on a machine with **Enable sudo** switched
  off, which is a green line for something that then fails at the point of use. The
  switch is `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo` → `Enabled`, and on a
  machine that has never enabled it the value is **absent rather than 0** — so treat "no
  such property" as disabled.

  `wezterm-windows.lua` still uses the binary test, and therefore can still offer a
  `PowerShell (Admin)` entry that fails. That is a known gap rather than an oversight:
  the config is evaluated several times per process and deliberately does no
  `run_child_process`, so it has no cheap way to read the registry. The failure is at
  least self-describing — `sudo` prints why it is disabled — but if this needs closing,
  the route is `deps.ps1` writing a marker the Lua can `io.open`, with the staleness that
  implies.

## Key Conventions

- **OS portability:** `_OS=mac|linux` detected in `bashrc`. Mac/Linux differences (homebrew paths, `date` flags, `stat` flags) are handled inline with conditionals.
- **Bash version:** `bash/deps.sh` installs bash 5 via homebrew. Bash 4+ features (`dirspell`, `globstar`) are guarded with `BASH_VERSINFO` checks.
- **Tool dependencies:** `zoxide`, `fzf`, `bat`, `eza`, `fd`, `ripgrep`, `gh`, `jq`. All optional — features degrade gracefully via `command -v` guards. Declared in `deps.conf`'s `[bash]` section, installed via brew/apt/dnf. Some tools have alternate binary names on RHEL/Debian (`bat` → `batcat`, `fd` → `fdfind`) — handled with fallback checks.
- **Symlink pattern:** `install.sh` symlinks `bash/*` to `~/.*` (e.g. `bash/bashrc` → `~/.bashrc`), driven entirely by the `link` lines in `deps.conf`. It hard-codes no filenames — adding or renaming a config file is a manifest edit and nothing else. Renames are safe because `install.sh` **prunes orphans**: a symlink pointing into this repo whose target no longer exists is removed, so the retired name can't survive next to the new one. That test is structural on purpose — don't replace it with a list of old names, which would need maintaining and would silently stop covering the next rename.
- **Navigation UX:** All interactive fzf commands use consistent keybindings — menus (`-`/`q` back, `?` help), lists (type to filter, `esc` back, `ctrl-r` refresh, `ctrl-o` browser, `ctrl-/` help; a screen's own keys are in its footer). This is not a convention to remember: the menu contract lives in `__fzf_menu` (`bash/bash_productivity`), every screen calls it, and CI rejects a hand-rolled `fzf --disabled`. It used to be 18 copies of the same `--bind` string. In `gh-tui`, screens open *inside* the screen below them (fzf `execute()` running a nested fzf), so `esc` returns to the row you left — that is deliberate, and it is why the screens live in the worker script the file writes per session rather than as parent-shell loops; see the header of `bash/bash_github_tui`.
- **`gh-tui` needs fzf ≥ 0.65** — `--listen` for live previews, `--style`/`--footer` for the chrome. `deps.conf` puts fzf on `mise||pkg` for exactly the reason nvim is, and `bash/deps.sh` enforces the floor over an already-installed distro fzf. Don't lower it to fit an old apt; raise the distro instead.
- **`h` is hand-maintained, and CI keeps it honest.** Adding, renaming or removing a command means editing `h` in the same commit. A CI step asserts both directions — every public function and alias is named in `h`, and every command in `h`'s quick reference actually resolves. Both had already drifted: `h` advertised `gh-tui` while the function was `gh-ui`, and kept a full help page for `lines` after it was deleted.
- **The `[bash]` file split is enforced, not conventional.** `bash_git` (git porcelain) → `bash_github` (plain `gh` + shared helpers) → `bash_github_tui` (everything interactive), sourced in that order. Only the TUI file may invoke fzf, and CI checks it — that boundary is what keeps the interactive layer replaceable as a unit. How it is built and why: [`docs/decisions/github-tui.md`](docs/decisions/github-tui.md).
- **`mise.toml` and `mise.lock` are generated.** `deps.conf` is still the only place tools are declared; `tools/gen-mise.sh` derives the mise-provided subset from it and `mise lock` adds per-platform checksums. Run `make mise-lock` after touching a mise tool. Don't hand-edit the tool list (versions are fine to edit — regenerating preserves them).
- **Machine-local config:** `~/.bash_local` (per-machine paths and exports) and `~/.bash_password_commands` (secrets) are optional-sourced by `bashrc`. They live **in `$HOME`, never in the work tree** — do not "tidy" them back into `bash/` with a `.gitignore` entry, which is how they used to be. Outside the tree, git cannot see them; inside it, protection is a rule that `git add -f` overrides and that a `.gitignore` rewrite silently deletes. They're also the only configs not declared in `deps.conf`, and must stay that way: the manifest describes what _every_ machine gets.

## When Editing

- Test on both bash 3.2 (macOS `/bin/bash`) and bash 5+ (homebrew / Linux).
- Guard all tool usage with `command -v` checks.
- Keep the `h` help function in `bash_productivity` in sync with any command changes.
- The README is intentionally concise: install + new-machine flow + GitHub tools pointer + "what goes where" table. Prose explanations of bash internals belong here in `CLAUDE.md`, not in the README.
