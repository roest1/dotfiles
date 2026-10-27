# CLAUDE.md

## Overview

Cross-platform dotfiles — terminal, editor and shell as one versioned unit. Installed personally on Linux Fedora, WSL Ubuntu, and SERHEL. Bash-based. Windows installation exists. A monorepo.

**macOS is not supported, since 2026-10-26.** There is no Mac to run this on,
and the two `macos-latest` CI jobs that were the whole of the support claim are
gone with every Darwin branch, brew cask and bash 3.2 workaround they existed
for. The rule they imposed -- prefer the construct BSD userland can run -- is
retired with them: the targets are Fedora, RHEL, Ubuntu under WSL and the
Windows host, and GNU spellings are fine. Portable constructs already in the
tree were left where they cost nothing. What was removed and what it would take
to bring it back: [`docs/decisions/macos.md`](docs/decisions/macos.md).

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

`make status` reads the same file, because an opt-out is not drift — and it *names* the
sections it skipped rather than dropping them silently, since a section added to
`deps.conf` after the file was seeded is missing from it by accident, not by choice.

**`dots` writes this file** — space on a section row toggles it — which is the reason to
reach for the console over an editor here. Absent and everything-commented-in are *not*
the same state, and that is invisible in a text editor: with the file present this machine
sweeps exactly the names in it, so a section added to `deps.conf` later arrives **off**,
where a machine with no file picks it up. The console names which of the two is in force
and carries a row that deletes the file to get back to the first. Details next to the
code: [`tui/CLAUDE.md`](tui/CLAUDE.md).

see `make help`

`make check` asks "does this command exist." `make status` asks "is this machine
what the manifest says" — link targets, per-tool provenance, and the font lanes.
Prefer `status` when the question is whether the repo is still telling the truth.

The font block is the one part that admits a limit rather than answering. It
reports what a program can prove — the files are where `font_dirs` points, and
what `wezterm ls-fonts` actually resolved the family to — and then runs
`font show`, whose carrier prints real SGR 6 and SGR 5 text for the half only an
eye can read. **Only the provable half counts as drift**, because the carrier is
unreadable over ssh, in a pipe and on any other terminal, and counting it would
report red on machines that are fine. This replaced a `wezterm/MIN_VERSION`
floor that inferred render-time behavior from a build stamp; don't restore it,
for the reason in `wezterm/deps.sh` — a floor cannot fail safe, so every build
above it passed untested and the silent failure survived inside a green tick.

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

**`[uv]` is the one section that prefers an official installer over `pkg` on purpose**,
and it will read as a violation of the paragraph above if you don't know why. The
distro's uv has `uv self update` compiled out, so it is stuck at whatever the distro last
packaged — Fedora 44 sat on 0.11.32 against upstream 0.12.9 — while uv ships weekly. That
is a capability difference rather than a version floor, so no `||` chain can express it:
`manual` installs nothing, and chains are tried before any `deps.sh` runs, so
`manual||pkg` installs the distro copy first and never reaches the installer it is
supposed to prefer. The preference therefore lives in `ensure_uv` (`lib/pkg.sh`), which
curls astral.sh and falls back to `pkg` only when the network is unreachable.
`uv/deps.sh` reports — and deliberately never removes — a distro uv already on the
machine, for the reason in `docs/decisions/tool-duplication.md`.

That move is also why `uv` is not in `[bash]` any more: that section may not depend on a
curl-piped installer, and `2parquet`/`2feather`/`2pickle` guard on `command -v uv` so it
doesn't have to. And it is why `uv/uv.toml` is tracked — `python-downloads = "manual"`
and `python-preference = "system"` came from `/etc/uv/uv.toml`, which the RPM owns, so
uninstalling the package to get a self-updatable uv would have silently reverted both.

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
  every other terminal: **rapid blink**, over ssh, in GNOME Terminal, in a plain console. And being
  *in* WezTerm still isn't enough, because WezTerm only honours the attribute if this
  repo's config is the live one — on a machine that hasn't run `make link`, or one
  pointed at a stock config, it blinks again. The linked font directory is the cheapest
  true proxy for that, since `deps.conf` links config and fonts together. All three
  directions are asserted in the `manifest` CI job, because none of them is visible to
  whoever writes the code — they're always in WezTerm, always on a tty, always linked.

  Italic looks like the obvious carrier and is wrong: rose-pine italicises nvim's
  comments, so the whole editor would silently change font.

  **`lib/tty.sh` is the sibling file, and the split between them is the guard,
  not the feature.** It holds the escapes that need a terminal but
  nothing about *which* terminal — the green/red/yellow marks in `make status`,
  and the decrypt animation on `make help`'s banner. Green means green and `\r`
  means `\r` everywhere, where SGR 6 means *rapid blink* off this setup.

  So the two files ask different questions. `sgr.sh` asks "is this WezTerm,
  running our config". `tty.sh` asks "is this a terminal at all, and does its
  owner want decoration" — a tty, `TERM` not `dumb`, and `NO_COLOR` unset.
  **`NO_COLOR` is tested for being SET, not for being non-empty**: the spec says
  any value including the empty string means no, and `[ -n "$NO_COLOR" ]` is
  exactly how that gets missed. CI asserts the empty case on its own for that
  reason. `TERM=dumb` is the value defined as having no capabilities, so CSI
  lands in it as literal text — an animation there is not a degraded effect,
  it is garbage.

  The animation is gated on `NO_COLOR` too, which reads past the letter of a
  spec that only governs color. It is right anyway: the banner is decoration by
  exactly the argument `NO_COLOR` is making, and someone who asked for less has
  not asked for more. `TTY_ANIM` is computed separately from the color block so
  the two can diverge if that turns out to be wrong. Folding the two together would have put two
  different guarantees behind one set of variables whose header promises "empty
  unless all three hold", and a caller could no longer tell which it was getting.

  The cost is real and worth naming: the CI row that used to assert **no escape
  at all** reaches a non-wezterm tty can no longer say that, because the banner
  legitimately animates there. It now asserts the absence of both *carriers*
  (SGR 6 and SGR 5) instead, plus the presence of the cursor-hide escape — that
  last one in the other direction, so `lib/tty.sh` cannot quietly acquire
  `lib/sgr.sh`'s three conditions and go plain everywhere without failing.
  Probing that with `\r` would have passed vacuously: `script(1)` writes CRLF,
  so a carriage return is in the capture whether anything animated or not.

  **`tty_banner` runs two effects on ONE frame clock**: the banner decrypts
  while every menu row types out. Sharing the clock is why they compose — run
  in sequence they would be two delays stacked and `make help` would cost the
  sum; together the whole thing is one ~400ms budget. The budget is a TOTAL,
  not a per-character delay, because the obvious 50ms-a-character spelling gets
  slower every time a target is added, silently.

  **The rows type in PARALLEL, not one after another.** Sequentially, 22 rows
  at any readable speed is several seconds. In parallel the menu costs the same
  as its longest row — and because typing runs left to right and `make <target>`
  is the left column, the useful half is legible at ~25% of the budget, with the
  descriptions you already know arriving last.

  There was an intermediate design where only the banner animated and the menu
  printed instantly, and the reason it lost is worth keeping: it was chosen
  because a *sequential* typewriter leaves the menu unreadable for its whole
  duration, which is a real cost on the command you run when you are lost. The
  parallel version does not have that property, which is what made the trade
  affordable. If this ever feels like a tax again, that intermediate shape is
  the fallback, not "make it faster".

  That buys two more preconditions, both decided *before* anything is printed,
  because once a half-drawn menu is on screen there is no safe way back — the
  same cursor movement would be needed to undo it. The output must fit the
  screen, and no line may wrap: a wrapped line occupies two screen rows, so the
  up-count undercounts and the cursor scribbles into the middle of the menu.
  Measuring the width means stripping the escapes first, since the SG codes are
  zero-width on screen but are characters in the string.

  Scrolling is *not* one of the failure modes, which is the case that looks
  fatal and isn't: relative cursor movement survives a scroll, because the
  banner and the cursor move up together. Running `make help` at the bottom of
  a full screen is fine.

  **CI compares the animation's FINAL FRAME against the plain render**, and
  that is the assertion worth keeping rather than the byte-order one it
  replaced. The animation may hide characters that are about to arrive; it may
  never drop one. A bug in the escape-aware prefix walk would truncate a row and
  the final frame would still look entirely plausible — only the comparison
  catches it. (A row cannot be cut with `${row:0:k}`: the SG codes are
  zero-width on screen but real characters in the string, so slicing by
  character both miscounts and can sever an escape, leaving the terminal in
  whatever state the fragment implied. Each row is walked once and snapshotted
  at the frame points instead.)

  Both CI rows drive `script(1)` with an explicit `stty rows 50 cols 200`. A
  runner's pty is unsized until something sets it — `stty size` reports `0 0` —
  so without it the animation would correctly decline and the row asserting it
  happens would fail for a reason unrelated to the guard being tested.

  **The screen size comes from `stty size < /dev/tty`, never `tput`.** `tput
  lines` needs a valid `$TERM` and exits 2 with *"No value for $TERM and no -T
  specified"* without one — and CI sets no TERM, so the tput version declined on
  every runner and failed the row asserting the animation happens. `stty` reads
  the ioctl and never consults terminfo, so it answers in strictly more places.
  It has to read `/dev/tty` rather than fd 1: inside `$( )` fd 1 is the capture
  pipe, so `stty size <&1` reports *"Inappropriate ioctl for device"*.

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
  no `fc-cache` (which Windows hasn't got), no per-platform font directory
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

- **A wezterm symptom is a stale-process or wrong-clone question before it is a
  wezterm question.** `wezterm --config <name>=<value> start` opens a window with
  that value forced, independent of any file, symlink or reload — so it separates
  "the setting does not work" from "this process never read the setting" in one
  command. It settled a multi-hour hunt in which `text_blink_rate_rapid = 0`
  appeared to be ignored: the value was correct, the running GUI predated it, and
  the Windows clone was on an older commit besides.

  Two corollaries worth reaching for before reading any renderer source.
  `wezterm ls-fonts` prints the file each rule resolved to, which is the only way
  to tell a correct config from a font shadowed by a system-installed copy of the
  same family. And a running wezterm does not pick up a pulled config: a tab
  switch is not a reload, and the file watcher does not reliably follow a symlink
  across a volume boundary, so `Get-Process wezterm* | Stop-Process -Force` is
  part of the test rather than an afterthought.

  The asymmetry that makes this bite: wezterm **warns** when a `font_rule` cannot
  be matched, and says **nothing** when a fallback resolves. A wrong-but-valid
  font is silent by design.

- **`ln -s` run inside WSL onto `/mnt/c` produces a link Windows cannot follow.** It
  writes an _LX symlink_; Windows fails on it with `STATUS_IO_REPARSE_TAG_NOT_HANDLED`.
  Ordinary file _writes_ to `/mnt/c` are fine — this is specific to symlinks. Nor will
  `wezterm.exe` load a config over `\\wsl.localhost\...`; the maintainer has said the WSL
  filesystem isn't visible to the host that way. Hence a second clone on `C:` and a
  PowerShell installer, rather than teaching `install.sh` to reach across.
- **`Exec format error` from `clip.exe` is a lost binfmt entry, not a PATH problem.** A
  WSL guest runs `.exe` files through a `binfmt_misc` entry WSL writes into `/proc` at
  boot, with no `binfmt.d` file behind it. With `systemd=true`, any package upgrade that
  ships a `binfmt.d` rule (python3.12 did) restarts `systemd-binfmt`, which unregisters
  every entry and restores only those with a file, so interop is gone until WSL reboots.
  Re-sourcing `~/.bashrc` can't reach it. `ensure_wsl_interop` in `lib/pkg.sh` writes
  `/etc/binfmt.d/WSLInterop.conf` (both `bash/deps.sh` and `nvim/deps.sh` call it), and
  `make status` reports it under `[wsl] interop`. Check for both `WSLInterop` and
  `WSLInterop-late`: a systemd WSL registers the latter, so testing one name alone calls
  a working machine broken.
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

- **OS portability:** Linux only on the shell side (Fedora, RHEL, Ubuntu under WSL); the Windows host has its own installer. There is no `_OS` variable any more. WSL is detected at runtime (`is_wsl`) where the guest and the host differ.
- **Bash version:** bash 5 on every target. The `BASH_VERSINFO` guards and 3.2-safe constructs in the tree are from when macOS was one, and stay because they cost nothing.
- **Tool dependencies:** `zoxide`, `fzf`, `bat`, `eza`, `fd`, `ripgrep`, `gh`, `jq`. All optional — features degrade gracefully via `command -v` guards. Declared in `deps.conf`'s `[bash]` section, installed via brew/apt/dnf. Some tools have alternate binary names on RHEL/Debian (`bat` → `batcat`, `fd` → `fdfind`) — handled with fallback checks.
- **Symlink pattern:** `install.sh` symlinks `bash/*` to `~/.*` (e.g. `bash/bashrc` → `~/.bashrc`), driven entirely by the `link` lines in `deps.conf`. It hard-codes no filenames — adding or renaming a config file is a manifest edit and nothing else. Renames are safe because `install.sh` **prunes orphans**: a symlink pointing into this repo whose target no longer exists is removed, so the retired name can't survive next to the new one. That test is structural on purpose — don't replace it with a list of old names, which would need maintaining and would silently stop covering the next rename.
- **Navigation UX: there are no interactive fzf commands left.** `__fzf_menu`/`__fzf_list` in `bash/bash_productivity` held the menu-and-list contract — `-`/`q` back, `?` help, type-to-filter, `esc` back — defined once because it had been 18 copies of the same `--bind` string. All 18 call sites were in `bash_github_tui`, so the Rust port left the wrappers with zero callers and they were deleted with the layer they served (`bash_git` never invoked fzf). The only fzf left in the shell is fzf's own Ctrl+R / Ctrl+T / Alt+C integration.

  The contract and the CI row that policed it are in git history, and the argument for centralising the binds still holds — so if an fzf screen is ever wanted again, bring both back together rather than the wrapper alone.

  The Rust TUIs (`github`, `dots`, `font`) have their own contract — hjkl between regions, `q` back, each region stating its keys in its own footer — and it is deliberately not that one. Details next to the code: [`tui/CLAUDE.md`](tui/CLAUDE.md).
- **fzf has no version floor, and must not get one back without a caller that needs it.** There was one, 0.65, enforced in `bash/deps.sh` over an already-installed distro fzf, and it existed for `github` — `--listen` and the start/focus events for live previews, `--style`/`--footer` for the chrome. `github` is a Rust binary now and uses no fzf; the menu wrappers that were the only other candidate went with it. All that is left is fzf's own Ctrl+R / Ctrl+T / Alt+C integration, which falls back to the packaged completion script on an fzf too old for `--bash`, so nothing has a version to state and `deps.conf` is back to `pkg||mise`: one binary from the distro. A floor cannot fail safe — every version at or above it passes untested, which is why `wezterm/MIN_VERSION` went — and a floor with no caller at all is worse, because it forces a second fzf onto machines whose own was fine.
- **`h` is hand-maintained, and CI keeps it honest.** Adding, renaming or removing a command means editing `h` in the same commit. A CI step asserts both directions — every public function and alias is named in `h`, and every command in `h`'s quick reference actually resolves. Both had already drifted: `h` advertised `gh-tui` while the function was `gh-ui`, and kept a full help page for `lines` after it was deleted.
- **Pruning is measured, and the measurements live in `$HOME`, never in the tree.**
  The June 2026 nvim cleanup deleted ~40 mappings on judgement and `nvim/doc`
  described them for four months afterwards. Two records now exist so the next
  cut is a deletion of zeros: `~/.bash_history`, which `bashrc` appends after
  every prompt and stamps with a date (a shell closed on its window button used
  to lose everything since it opened), and `~/.local/state/nvim/keymap-usage.json`,
  written by `nvim/lua/external/usage.lua` and read by `:KeymapUsage`.
  `tools/usage.sh` prints both, zeros first. Neither file is under the work
  tree, by the same argument that keeps `~/.bash_local` out: git cannot commit
  what it cannot see. Do not add a log that lives in the repo, and do not move
  these under `~/.config/nvim`, which is a symlink into it. One machine's
  history is one machine's evidence -- a zero means "not here, not since the
  record began", and the `[Certain]` version needs the same read on each box.
  The editor side has the CI guard the shell always had: `nvim/doc` is checked
  against `nvim/lua` in both directions (see `nvim/CLAUDE.md`).
- **The `[bash]` file split is enforced, not conventional, and it has now paid for itself.** `bash_git` (git porcelain) → `bash_github` (plain `gh` + shared helpers) → `bash_github_tui` (everything interactive), sourced in that order; only the TUI file could invoke fzf, and CI checked it. That boundary is what made replacing the interactive layer a **deletion** rather than a rewrite: `github` is `tui/github` now, `bash_github_tui` is gone, and `bash_git`, `bash_github` and `gha` were untouched by the swap. The CI row survives the file, because `bash_github` is still the plain-`gh` file and a screen growing back into it is the drift to catch. How it was built, ported and swapped: [`docs/decisions/github-tui.md`](docs/decisions/github-tui.md), and what the port chose not to carry: [`docs/decisions/github-parity.md`](docs/decisions/github-parity.md).
- **`mise.toml` and `mise.lock` are generated.** `deps.conf` is still the only place tools are declared; `tools/gen-mise.sh` derives the mise-provided subset from it and `mise lock` adds per-platform checksums. Run `make mise-lock` after touching a mise tool. Don't hand-edit the tool list (versions are fine to edit — regenerating preserves them).
- **Machine-local config:** `~/.bash_local` (per-machine paths and exports) and `~/.bash_password_commands` (secrets) are optional-sourced by `bashrc`. They live **in `$HOME`, never in the work tree** — do not "tidy" them back into `bash/` with a `.gitignore` entry, which is how they used to be. Outside the tree, git cannot see them; inside it, protection is a rule that `git add -f` overrides and that a `.gitignore` rewrite silently deletes. They're also the only configs not declared in `deps.conf`, and must stay that way: the manifest describes what _every_ machine gets.

## When Editing

- Test on bash 5 (Fedora, RHEL 9, Ubuntu 24.04). bash 3.2 stopped being a target with macOS.
- Guard all tool usage with `command -v` checks.
- Keep the `h` help function in `bash_productivity` in sync with any command changes.
- The README is intentionally concise: install + new-machine flow + GitHub tools pointer + "what goes where" table. Prose explanations of bash internals belong here in `CLAUDE.md`, not in the README.
