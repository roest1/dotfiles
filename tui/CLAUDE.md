# CLAUDE.md — `tui/`

## Overview

The Rust terminal UIs. One crate per screen, **one binary per command** —
`dots` here; `font` and `github` in their own repos,
[roest1/theme-tui](https://github.com/roest1/theme-tui) at `tui/font` and
[roest1/github-tui](https://github.com/roest1/github-tui) at `tui/github`, both pinned as submodules. They share
[roest1/tui-core](https://github.com/roest1/tui-core) (the framework, `tui_core::…`) and nothing else, because a font picker and a CI dashboard have
nothing else in common.

They are *not* modes of one program. `font` opens the font picker; `github`
opens the GitHub screens. That is the shape Riley asked for and it is also
what keeps each binary's startup honest.

**Each crate is a library plus a thin binary**, which is what lets that hold
while `make it` still reaches everything. `tui_core::app::run` and `Flow::Push`
both take `Box<dyn Screen>` from anywhere, so a screen is reusable across
binaries: `font` runs `font::screen()` (its Fonts and Colors tabs) as its root, and
the console pushes the SAME thing as a row in its tree. One implementation, two doors. The alternative was a
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
and is the same on any machine. `tui_core::tests::one_big_step_matches_several`
pins that.

## Layout

The framework is a Cargo git dependency on roest1/tui-core, declared once in
`[workspace.dependencies]` and pinned by `Cargo.lock`. Its notes are in its own `CLAUDE.md`.
Bump it with `cargo update -p tui-core` (Dependabot does it monthly). To work on it next to
these crates, clone it to `~/github/tui-core` and build with
`--config "patch.'https://github.com/roest1/tui-core'.tui-core.path='$HOME/github/tui-core'"`.
That build rewrites `Cargo.lock` to the unpinned path, so run `git checkout tui/Cargo.lock`
before committing; CI's `--locked` build fails on a lock left that way. Never commit a
`[patch]` or a path dependency on tui-core.

`tui/font` (roest1/theme-tui) and `tui/github` (roest1/github-tui) are submodules, excluded
from this workspace: each is its own package with its own `Cargo.lock`, and `tui/deps.sh`
installs each from its path. Their notes are in their own `CLAUDE.md`. `dots` depends on
`font` by path (`../font`), so it builds that screen against this workspace's single
tui-core; that is why `font` uses the same tui-core spec as here.

- `dots/` — the console. `repo` (reads the Makefile and `deps.conf`; the only
  file that parses either), `sections` (the machine-local sections file — the
  only thing here that is WRITTEN), `console` (the tree), plus the lib/bin pair.

## Things not to undo

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
  `make shell` wrapped its recipe in `ifeq ($(UNAME),Darwin)` (gone with macOS
  support), the scanner read the directive as a new rule, and the escalation
  was attributed to no target at all — the tree and the console agreeing when they did not, which is the
  exact failure the test exists to prevent.

## Adding a screen

1. New crate under `tui/`, `impl tui_core::Screen`.
2. Add it to `crates=(...)` in `tui/deps.sh` and a `tool manual <name>` line to
   `deps.conf`'s `[tui]`.
3. Do not add keys to `tui_core::nav` for one screen — `Action::Key(char)` is
   the escape hatch, and it exists so the shared table stays shared.
4. Prefer a ROW over a key for anything a newcomer has to discover. `Flow::Push`
   makes a row into a screen.
