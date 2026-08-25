# CLAUDE.md — `tui/`

## Overview

The Rust terminal UIs. One crate per screen, **one binary per command** —
`font` and `dots` today, `github` next. They share
`reticle/` and nothing else, because a font picker and a CI dashboard have
nothing else in common.

They are *not* modes of one program. `font` opens the font picker; `github`
will open the GitHub screens. That is the shape Riley asked for and it is also
what keeps each binary's startup honest.

**Each crate is a library plus a thin binary**, which is what lets that hold
while `make it` still reaches everything. `reticle::app::run` and `Flow::Push`
both take `Box<dyn Screen>` from anywhere, so a screen is reusable across
binaries: `font` runs `FontScreen` as its root, and the console pushes the SAME
type as a row in its tree. One implementation, two doors. The alternative was a
second font screen living inside the console, which is how the two drift.

The binaries stay honest because a binary links what it uses: `font` still
starts in ~1ms and pulls in a picker, not a CI dashboard. It is the console
that depends on everything, which is correct — it is the thing that shows
everything.

## Why Rust here and not elsewhere

The fzf picker this replaced re-spawned a previewer on **every cursor move** —
~300ms a keystroke, most of it `uv` startup and re-parsing fonts that had not
changed. The architecture was the problem before the language was: a persistent
process parses once and renders from memory.

Rust then buys the rest. Startup is ~1ms against 130ms, and the reticle can
hold 60fps *while* rasterising type. `lib/tui.sh` on `feat/make-console`
advances its animation once per `read -n1 -t 0.03`, so it moves at whatever
rate the terminal delivers keystrokes; here the step is driven by elapsed time
and is the same on any machine. `reticle::tests::one_big_step_matches_several`
pins that.

## Layout

- `reticle/` — the framework. `term` (raw mode, alt screen, restore-on-panic),
  `nav` (the keymap), `reticle` (the animated brackets), `screen` (what a
  screen provides), `app` (the loop), `image` (inline images).
- `dots/` — the console. `repo` (reads the Makefile and `deps.conf`; the only
  file that parses either), `sections` (the machine-local sections file — the
  only thing here that is WRITTEN), `console` (the tree), plus the lib/bin pair.
- `github/` — the port, root-first. `index` (every clone under `~/github`, read
  from disk), `root` (the repo tree), plus the lib/bin pair. **Not installed
  yet** — see below.
- `font/` — two screens, and a LIB plus a thin bin. `lib` (the module index
  and the crate-root re-exports), `picker` (the lane tree — the root screen),
  `fonts` (discovery + measurement), `render` (rasterising, the contact sheet,
  glyph-distinctness), `lanes` (the machine-local `fonts.conf`), `fetch` (the
  prefetching cache behind the browse screen), `browse` (the Google-fonts
  screen), `show` (`font show` — the lane report and the carrier), `main`
  (argument handling and nothing else).

## Things not to undo

- **The pane clears its text region AFTER placing the image, not before.** An
  inline image is a negotiation, not an API: the terminal scales it by rules
  this process cannot see. Asked for a 147x14-cell sheet, wezterm bound on the
  WIDTH and returned it ~31 rows tall, straight over every metric below it. So
  the image is now sized by HEIGHT only, and the text region is blanked
  afterwards so anything it spilled gets overwritten. Both halves matter — the
  second is what makes a wrong guess survivable.
- **The two redraws are deliberate.** `app` redraws the row list per frame and
  the right-hand pane only when the *selection* changes, because the pane can
  hold an ~88KB PNG. Re-sending that at 60fps is ~5MB/s down a pty for an
  animation the image is not part of. See the header of `app.rs`.
- **cargo is required, and this section does not apologise for it.**
  `tui/deps.sh` used to warn and return 0 when Rust was absent, so `make
  install` finished green and left the picker missing — the silently-dead
  install `[nvim]` already learned from. It now fails loudly, because not
  wanting Rust finally has a real place to live: leave `tui` out of
  `~/.config/dotfiles/sections`. An opt-out that survives a pull is worth more
  than a skip that pretends the install worked. `ensure_cargo` (lib/pkg.sh)
  installs rustup if it has to; CI asserts there is no second copy of that
  bootstrap here.

  rustup rather than the distro package, which inverts this repo's usual
  preference for the same reason [nvim] does: the workspace sets a
  rust-version floor and distro rust lags it, so a too-old toolchain fails at
  the END of a long install rather than the start.
- **`deps.conf` says `manual`, not `cargo`.** The cargo provider installs by
  crate NAME from crates.io, and `font` is a name someone else owns there — it
  would install a stranger's crate and report success. The install is
  `cargo install --path` in `tui/deps.sh`. CI asserts both halves.
- **No bash function may be named after a binary here.** A shell function wins
  over PATH, so a `font()` in `bash_productivity` would silently reinstate the
  picker this replaced. CI asserts it.
- **The reticle must settle.** If `Reticle::moving()` never goes false, `app`
  polls on a 16ms timeout forever and the process spins at 60fps showing a
  static list. There is a test for exactly this.
- **Prefetch is driven by `Screen::focus`, not by `pane`.** A row you skim past
  without stopping on still has to be fetched — that is precisely what makes the
  NEXT keypress instant rather than the current one slow. `pane` only ever sees
  where you stopped.
- **`Fetcher::request` checks the disk synchronously.** Leaving that to the
  worker meant a family cached from a previous session still went Pending →
  queue → thread → Ready, so moving across fonts you had already fetched
  flashed "fetching…" every time. A `read_dir` costs microseconds.
- **You cannot rasterise a font you do not have.** "Preview without
  downloading" is not a thing; preview without INSTALLING is, and that is what
  the cache is for. Nothing reaches `~/.local/share/fonts` without Enter.
- **There is ONE implementation of "measure a font", `fonts::measure`.** The
  Python previewer that used to carry a second one was deleted because the two
  had already drifted on which file counted as Regular. (This bullet used to
  name a `font inspect` subcommand and a `fontbrowse` bash caller; neither
  exists — the command surface is the three below, and browsing is a row inside
  the picker. The principle outlived both spellings.)

- **`font show`'s carrier is the only part of this crate that does not
  rasterise.** Everything else here draws type by decoding the file with fontdue
  and shipping a PNG, which is why the picker looked perfect on a machine where
  the lanes were dead: a rasterised specimen is a picture of what this process
  thinks the font is, not of what wezterm did with it. The carrier prints real
  SGR 6 and SGR 5 text and lets the terminal answer. Do not "unify" it with the
  rendering path — the whole value is that it goes through the code being tested.

  It replaced a version floor (`wezterm/MIN_VERSION`) that inferred the same
  answer from a build stamp. That could not fail safe: every build at or above
  the floor passed untested. Don't bring it back — `status_fonts` in
  `lib/status.sh` asks the provable half, and this asks your eyes.

  Each sample resets with `\x1b[22;25m` immediately after itself, so a
  truncated line cannot leave the terminal in SGR 6 and silently reskin
  everything printed after it.

- **`font show` exits non-zero ONLY for a lane naming a family this machine does
  not have**, because that is the only thing here a program can judge.
  `status_fonts` counts that as drift and counts nothing else, so `make status`
  stays green over ssh, in a pipe and on a non-wezterm terminal — all places the
  carrier is unreadable and the machine is fine.

  Inside WSL it reports `host` rather than MISSING, and exits 0. The guest has
  no fonts on purpose: wezterm.exe resolves families on the Windows side, so
  presence is UNKNOWABLE from in here, not false. Reporting MISSING would have
  made `make status` red on the platform this repo is most often driven from.

- **A screen's type is public; everything else can stay crate-private.**
  `lib.rs` re-exports `FontScreen`, `Preview` and `specimen` at the crate ROOT
  rather than making callers reach into `picker::`, because that is where they
  already lived when this was one file and `browse` addresses them as
  `crate::specimen` / `crate::Preview`. Keeping the paths identical is what
  made the lib/bin split a move rather than a rewrite.

  Making `new()` public turned on `clippy::new_without_default`, which only
  fires for public items — so the split surfaced two real omissions rather than
  inventing them. They got `Default` impls, not `#[allow]`: a type whose `new()`
  takes no arguments and cannot fail *is* `Default`, and saying so is the fix.

- **`dots` reads the repo; it does not restate it.** Target names and summaries
  are the `##` markers `make help` already renders, a target's long form is the
  comment block above its rule, and sections come from `deps.conf`. Nothing is
  authored twice, which has one consequence to actually absorb: **a comment
  above a rule in the Makefile is user-facing documentation now.** Write it for
  someone deciding whether to run the thing.

  A blank line ends a block. That is what stops a file-header banner being read
  as the first target's page, and how a target opts out of having a long form.
  The tests parse the REAL Makefile rather than a fixture, because the thing
  that breaks is not the parser — it is someone reformatting a rule and the
  console quietly losing a page.

- **`dots` READS the repo and OWNS `~/.config/dotfiles/sections`, and that
  split is the whole design.** Everything derived from the tree — targets,
  their pages, the section list — is the same on every machine by definition,
  so a console over it is a launcher. The sections file is the opposite: it
  exists to differ per machine, and until now nothing wrote it but an editor.
  A second store lands the same way (`~/.gitconfig.local` is the obvious next
  one) — machine-local, outside the work tree, whole file rewritten, delete it
  to get the default back. `font`'s `lanes.rs` was the first of these and this
  follows it deliberately.

  The rule that decides what may become a row: **a row under `dots` changes
  THIS machine.** `font` qualifies and is already pushed as one. `github`
  changes a repo on a server, so it is a sibling binary and not a row —
  otherwise the console becomes a launcher again, one screen at a time.

- **Absent and everything-ticked are DIFFERENT states, and rendering them
  identically is the bug this screen exists to avoid.** `manifest_enabled`
  prints the names it finds in the file, so a machine with no file gets
  whatever `deps.conf` declares *now and later*, while a machine with a file
  gets exactly the names in it — the same section added upstream arrives ON in
  one case and OFF, silently, in the other. Nine ticked boxes look the same
  either way.

  Hence `Mode`, hence the header saying which contract is in force rather than
  "all", and hence `follow deps.conf` being a ROW: nobody discovers that
  undoing a checklist means deleting a file whose path they would have to know
  first. `sections::tests::a_new_section_arrives_off_when_pinned_and_on_when_following`
  is the test that pins the distinction; if it ever goes, the header is lying.

- **Space toggles; Enter still opens.** The key that rewrites a file must not
  be the key that expands a tree — and the three verbs under a section are what
  you came for far more often than the toggle is. Space also works on the verb
  rows, so an open section is not three rows where its own switch stops
  working. The footer names the RESULT ("skip it here" / "sweep it here"), not
  the action, because `space toggle` makes you press it to find out which way
  it goes.

- **`set` writes and then RE-READS, rather than updating state from what it
  just wrote.** A read-only config dir then shows up as the toggle not moving,
  with the reason in the status line, instead of a ticked box over a file that
  never changed. Toggling everything off is allowed rather than prevented:
  `manifest_scope_into` refuses an all-off file and says how to fix it, so the
  failure is safe — but it fires at `make install` time, possibly days later,
  so the console says so at the moment of the toggle.

- **Both modes add or drop a row, so `at()` and `rows()` can drift.** That is
  the exact bug the `At` enum was introduced to prevent, now with a moving
  target. `console::tests::walk_agrees` asserts every selectable index resolves
  to the row actually drawn at it, in all three shapes (following, pinned,
  section open). Do not add a conditional row without extending it.

- **`github` builds but does not install, and that is the whole plan.** A bash
  function beats PATH and `github()` is still defined in `bash_github_tui`, so
  a `github` binary installed now could not win anyway — CI asserts the rule.
  It is therefore absent from `deps.conf` and `tui/deps.sh` until the commit
  that deletes the bash function adds it to both. Develop with `cargo run -p
  github`. Do NOT wire up a half-ported `github` that dispatches to both
  halves; replacing that file as a unit is exactly what the CI rule "only
  bash_github_tui may invoke fzf" was built to allow.

- **`index` groups by PATH and identifies by REMOTE, because on the real tree
  neither can do both.** Measured before the reader was written:
  `~/github/orgs/codegig` holds the org `codegig-br`; depth is not fixed
  (`orgs/codegig/clients/shell/atlas`); `private/repos/jarvis-project` holds
  other people's clones; one repo has no remote. Grouping by owner would file
  someone else's clone under its own heading and have nowhere to put the
  remoteless one. So the lane comes from where you filed it and the slug comes
  from `origin`.

  Both are read as FILES — `.git/config` and `.git/HEAD` parsed directly, not
  `git config` and `git branch`. Twenty-seven process spawns is the difference
  between a screen that opens instantly and one you watch open, and instant is
  this screen's entire claim. `current()` walks up for `.git` rather than
  asking `gh repo view`, for the same reason plus working offline.

- **A row says the unusual thing and stays quiet otherwise.** The first version
  put `owner/name` on every row, which on the real tree is thirteen rows of
  `roest1/<the-directory-name>` under a heading that already said `roest1` —
  and the column truncates, so the noise pushed the genuinely different ones
  (`bilawalsidhu/gods-eye-view`, `local only`) off the end. Now the slug shows
  only when the directory was renamed or the owner is not the lane's, and the
  branch badge only when it is not `main`/`master`. Same rule as `dots`' `off`
  badge.

- **`Screen::initial_sel` is asked of the screen, not passed to it.** `github`
  inside a repo opens on that repo's row, and which row that is depends on
  which lanes the screen decided to open — a caller would have to reimplement
  the row walk to know. `app` clamps the answer to the rows actually drawn and
  skips a spacer, so a stale one cannot park the cursor in a blank row, which
  is the one place navigation otherwise never lands.

- **`dots` is not a make target, deliberately.** `make font` does not exist
  either. The console was called `make it` on `feat/make-console`, and keeping
  both a target and a binary would have been a second name for one thing —
  exactly the drift this repo keeps deleting. `make help` ends with a pointer
  at `dots` instead, so the discoverability a bare binary would lose is bought
  back for one line.

  A happy consequence: `dots` is no longer started BY make, so the
  `MAKEFLAGS`/`MAKELEVEL` inheritance the bash console had to unset cannot
  arise. That was on the salvage list and simply evaporated.

- **Twelve targets stream into the pane. Two detach. The split is sudo, and
  it is not a preference.** A child on the real tty can prompt for a password;
  a pane cannot, raw mode having already taken the keyboard. So `install` and
  `shell` — the only two that can reach `sudo`, via `pkg_install` and via
  `sudo tee -a /etc/shells` — hand the terminal back (`Flow::Detach`) and run
  where the real sudo can prompt in the open.

  **`dots` contains no sudo code at all**, and that is the design rather than
  an omission. Streaming those two would have required priming plus a
  credential keepalive (what `lib/tui.sh` did, holding a passwordless-root
  window open for the session), or an askpass helper, or `sudo -S` — and the
  last two put a password through this process. A feel-good feature does not
  buy that. sudo-rs does not change it either: escalation needs a setuid-root
  binary, so there is no "just for this app" install, and the problem is pty
  ownership rather than sudo's implementation language.

  `Terminal::suspend`/`resume` exist for the detach and are not `restore()`
  then `take()`: `take()` installs a panic hook wrapping the previous one, so
  re-taking per run would stack a hook per invocation for the life of the
  process.

- **`console::ESCALATES` is checked against the tree, not trusted.**
  `repo::sudo_files` and `repo::sudo_recipes` re-derive the escalating set and
  a test asserts the two agree, so a new `sudo` call site anywhere breaks the
  build rather than quietly arriving inside a streamed pane. The failure is
  worth stating: a target missing from `ESCALATES` gets STREAMED, and its
  password prompt fires into a pane that cannot show it.

  That test immediately earned itself twice. It found `bootstrap.sh`, which
  escalates and which `dots` can never run — excluded now as a claim about
  reachability rather than a convenience. And it found a bug in its OWN parser:
  `make shell` wraps its recipe in `ifeq ($(UNAME),Darwin)`, the scanner read
  the directive as a new rule, and the escalation was attributed to no target
  at all — the tree and the console agreeing when they did not, which is the
  exact failure the test exists to prevent.

## The command surface is three commands

`font`, `font show`, `font reset`. Everything else lives inside the TUI, which
states its own keys in the footer — including browsing, which is the last row
under an opened lane rather than a subcommand or a keybinding. A key you have
to be told about is a key nobody finds, and a subcommand is worse: it needs a
man page to discover something that could have been a row.

`app` keeps a screen STACK for this. `Flow::Push` opens one on top, `q` pops
below the root and quits at it, and each frame carries its own cursor, scroll
offset and reticle — so coming back lands on the row you left. That is the same
property github gets from running one fzf inside another, and it is the reason
github can move here without losing it.

## Sharpness, and where it comes from

An inline image is scaled by the terminal to fit the cells it is given, so a
canvas that is not already the right number of PIXELS gets resampled — and
resampled text is blur. `reticle::probe` asks the terminal for its cell size
(`CSI 16 t`) at startup and the canvases are built at exactly
`cols x cell_w` by `rows x cell_h`, so the image is drawn 1:1.

Nothing about the rasteriser was ever the problem. Verified by rendering
against a terminal that reports a 21px cell and checking the canvas comes back
at 21.00px per row.

## Theme, absorbed rather than parsed

Colours come from the terminal, not from `wezterm/wezterm.lua`: `OSC 11`, `OSC
10` and `OSC 4` return what it actually resolved, so a theme change is picked
up with nothing here aware that a theme exists. Parsing the Lua would have been
a second implementation of somebody else's format, wrong the first time that
file is rearranged.

Indices 16-255 are **computed** locally (`theme::xterm256`) rather than
required from the terminal — the 6x6x6 cube and the grey ramp are fixed by
xterm. That is what keeps the query an improvement instead of a dependency:
falling back to the foreground colour made the prompt specimen monochrome on a
quiet terminal, and only a test asserting the runs *differed* caught it.

The shell specimen renders **this machine's PS1**, read from `~/.bash_theme` —
the linked file. Change PS1 and the specimen changes. `theme::parse_ps1` is
split out from the file reading so it can be tested against the real string,
and CI asserts that string still matches `bash/bash_theme`.

## Left-column layout

Four slots, and three of them exist because the first version got it wrong:

- **label** — bold when the row is a `group`, so headers read as headers with
  no glyph needed to say so.
- **detail** — dim, and it starts a full `SPREAD_ROOM` past the label. That gap
  is not padding: it is exactly where the reticle's closing bracket reaches at
  full spread, and without it the bracket landed on the value —
  `[ nvim.editor ]etBrainsMono…`.
- **badge** — RIGHT-ALIGNED to the pane edge, with everything before it
  truncated to fit. Trailing it after a variable-length name put `GOOD` at a
  different column on every line and pushed the longest ones across the
  divider into the pane.
- **spacers** — `Row::spacer()`, skipped by navigation. A cursor that can rest
  in a blank row turns a grouping device into a pothole.

The reticle brackets the NAME, not the padded label, so a header padded for
column alignment does not render as `[ claude      ]`.

## Adding a screen

1. New crate under `tui/`, `impl reticle::Screen`.
2. Add it to `crates=(...)` in `tui/deps.sh` and a `tool manual <name>` line to
   `deps.conf`'s `[tui]`.
3. Do not add keys to `reticle::nav` for one screen — `Action::Key(char)` is
   the escape hatch, and it exists so the shared table stays shared.
4. Prefer a ROW over a key for anything a newcomer has to discover. `Flow::Push`
   makes a row into a screen.
