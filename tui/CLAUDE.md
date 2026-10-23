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
  screen provides), `host` (a screen that is several screens — the tab strip's
  other half), `width` (how many CELLS a string occupies), `app` (the loop),
  `image` (inline images).
- `dots/` — the console. `repo` (reads the Makefile and `deps.conf`; the only
  file that parses either), `sections` (the machine-local sections file — the
  only thing here that is WRITTEN), `console` (the tree), plus the lib/bin pair.
- `github/` — the port. `branches` (the full-width branch table), `menu` (a
  row's actions — the design's three-dots), `user` (the user level — the root, and its Account and
  Keys tabs), `orgs` (the org list and one org's three tabs), `index` (every
  clone under `~/github`, read from disk), `root` (the repo tree — the user
  level's Repos tab), `runs` (the Actions screen), `steps` (one run as a tree),
  `gh` (the threaded `gh api` caller and the cross-session cache), `scopes`
  (what the token may do, asked of the token), `model` (the API's types and the
  one place that says what a status MEANS), `render` (the pane bodies), `logs`
  (step slicing and log colouring), `time` (ISO 8601 without a date crate),
  `paint` (the palette), plus the lib/bin pair. **Not installed yet** — see
  below.
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

- **A placeholder row is a ROW, and `at()` has to count it.** The Environments
  screen draws "no environments yet" when the list is empty, so the rows below
  it sit where a single environment would have put them — and reading the
  position off `envs.len()` alone put `+ new environment` one row too high, on
  exactly the repo where creating one is the only thing the screen can do.
  `enter` on it did nothing.

  Same class as the `dots` console's conditional rows, and the same answer: the
  `At` walk and `rows()` are two readings of one list, so every screen with
  either gets a test asserting they agree — including in the empty shape, which
  is the one the first version of both got wrong.

- **`/` narrows the list, and no screen knows.** `app` filters the rows a
  screen returned and hands it `vis[sel]` — its OWN index — at the one boundary
  where the translation happens. So Actions, Branches, Orgs, Keys and the
  account screens all gained filtering in the commit that added it, without a
  line changing in any of them. Same trade as `Tick::Wake` and directional
  focus.

  **Substring, case-insensitive, ORDER-PRESERVING.** fzf did two things —
  matched loosely and reordered by score — and only the first is portable: a
  run list is newest-first because that is the question, and branches are
  grouped default-then-yours. A filter that reordered by score would answer
  "which matched best" over "what is going on here". Without ranking, a
  subsequence match is also worse than useless on short lists.

  Three things this had to get right, each found by using it:

  **A collapsed group survives any filter.** Its children are not in `rows` at
  all, so dropping it asserts there is no match inside when the filter cannot
  know. Collapsing a group while filtering emptied the screen with nothing on
  it to say why.

  **The cursor lands on a LEAF.** Landing on the heading above the match meant
  the next `enter` collapsed that group instead of opening what you searched
  for — which is how the blank screen above was reached.

  **`esc` clears the filter before it pops the screen**, and the footer says
  so. Otherwise a key pressed meaning "show me everything again" throws away
  the screen you were on.

  A filter in force is named in the footer when the field is closed. A list
  quietly hiding rows is the worst thing a filter can do.

- **`nav` has exactly two tables, and the mode lives there.** While a field has
  the keyboard a bare character is TEXT; otherwise it is `Action::Key(c)`.
  That is the whole reason filtering needed a framework change rather than a
  screen one — `o`, `r`, `b`, `e` would otherwise fire on the first letter of
  anything typed. `app` sets the mode from the frame on EVERY iteration rather
  than tracking it, so a push, pop, detach or tab switch cannot leave the
  keymap wrong; that failure would be silent and total.

  ctrl-c leaves from inside a field, because a field you cannot get out of is
  the one way this traps someone. ctrl-u clears it (PageUp outside). Arrows
  still navigate, so "type a bit, arrow down, enter" works.

- **`Flow::Ask` is screen-driven, and smaller than expected.** Filtering means
  the same thing everywhere so the framework does it; a VALUE only the screen
  knows what to do with comes back via `Screen::answered`, and the screen
  remembers what it asked — `app` carries the text and nothing else.

  One line, for IDENTIFIERS: a branch name, a secret's name, an environment.
  Anything longer already has a better answer, and finding that out is what
  made this small: **`gh pr create` and `gh pr edit` prompt for a title and
  body themselves**, on the real terminal, through `Flow::Detach`. The text
  widget was never the thing blocking PRs; filtering was.

  An empty or abandoned answer runs NOTHING. `--delete ""` is not something to
  find out about afterwards.

- **A menu item that changes something asks first, and "the tool reports" is
  not the same as "the tool asks".** That conflation was a real hole, wider
  than it looked: `git push --delete` prints what it did and fails loudly on a
  protected branch, and `gh api -X POST .../rename` does neither — so deleting
  a remote branch was ONE `enter` from a menu row, behind a note claiming the
  tool confirmed it.

  `Item::confirm()` asks; `danger()` implies it and adds "cannot be undone".
  Where the tool genuinely does stop and ask — `gh pr create` for a title, `gh
  auth refresh` printing a code and waiting — neither flag is set, so there is
  still only ever one prompt.

  **The confirm comes AFTER the field**, so what you approve is the command
  with the name you just typed in it rather than a template. Only `y` acts; any
  other key withdraws, and so does moving the cursor. `focus` clears it
  unconditionally rather than only on a change — `app` calls `focus` only when
  the cursor moved, so the guarded version was equivalent with a subtlety to
  reason about, and that subtlety is the sort of thing that leaves a delete
  armed.

  Because this lives in `Menu`, every screen's menu has it. That is the shared
  confirm the decision doc kept listing as open.

  The first version returned early with `continue` after handling a field,
  which silently dropped a `Flow::Push` or `Flow::Pop` from `answered` — a
  screen asking for a name and then opening something with it did nothing. It
  is an `if/else` so control still reaches the bottom of the loop.

- **hjkl moves between REGIONS, not just within the list.** `Tab` used to be
  the only way to reach the strip, and a key whose whole job is changing what
  the other keys mean is a mode — the thing the nav contract exists to avoid.
  Riley's word for the fix was a smart TV, and it is the right model: the EDGE
  of a region is the door to the next one.

  `k` on the first row goes to the strip; `h`/`l` there change tab and `j`
  drops back in. `l` on a row with nothing to expand goes right into the pane,
  where `j`/`k` scroll it and `h` comes back.

  **The rule that keeps the screens out of it: a direction acts within the
  region, and when it cannot, focus moves instead.** For `h`/`l` that is read
  straight off `Flow::Continue`, which already meant "nothing happened" — no
  screen had to change to take part.

  Two things this forced, both of which were wrong before and invisible:

  **`Action::Open` is not a synonym for `Activate`.** The github screens mapped
  `Activate | Open` together, so `l` on a run drilled into its jobs and the
  pane beside it could never be reached. `l` now only ever expands or moves
  right; `enter` does the thing. `Menu` takes `Activate` alone, because a
  second key that runs a delete is the one place an extra way to act is a cost.

  **Focus enters the pane whenever one EXISTS**, not only when it overflows.
  Gating on scrollability was the first attempt and it reads as a dead key: on
  a run whose body happens to fit, `l` silently did nothing — exactly the "why
  won't it move" the model is meant to remove. The divider lights up and the
  footer changes, so the move is visible either way.

  Only the focused region wears the reticle brackets, and each region states
  its OWN keys in the footer — the screen speaks for the list alone, since a
  footer still advertising `enter runs it` while the keys were talking to the
  pane is the kind of small lie that gets believed.

- **`reticle::width` measures CELLS, and the emoji ban it replaced was a bug
  fix pointed the wrong way.** Emoji were kept out of every fixed-width column
  because `✅` is one `char` and TWO cells, so a column of them drifted. That
  was arithmetic, not a reason to lose the one thing in a dense list you can
  find without reading — so the layout counts cells now and the glyphs are
  back: `✅ ok` / `❌ fail` badges, a 🔒 on a protected branch, and a glyph on
  every tab.

  `width()` skips ANSI escapes (characters in the string, nothing on screen),
  returns 0 for combining marks and variation selectors, and 2 for the
  emoji-presentation ranges. The ranges are written out rather than
  approximated because `↑` (2191) and `⭐` (2B50) are NEIGHBOURS of each other's
  blocks and are one and two cells respectively — an approximation that swept
  up a whole block would break the branch table's arrows. **Measured, not
  assumed: `⏭` is NARROW** (so the skip badge uses `⏩`), which is why the bash
  version wrote `"⏭ "` with a trailing space.

  **This confusion has now bitten three times in one session** — twice in a
  test and once in the pty harness — always the same way: `str::find` returns
  BYTES, `chars().count()` returns CHARACTERS, and neither is what the terminal
  does. If you are asserting alignment, assert `width::width`.

- **`Tab` is bound to nothing.** It moved the tabs for one commit, and that
  was wrong for the reason the whole directional model exists: a key whose only
  job is reaching a region is a mode by another name. Keeping it as a shortcut
  sounds harmless and is not — it is a second way to express one thing, so it
  is a second thing to learn, document and keep working. `k` off the top row
  reaches the strip and `h`/`l` move along it. The `Host` footer says so, since
  there is no key to discover.

- **`Split::Sidebar` is TWO row regions, and `hjkl` crosses them.** Filters
  left, list right — the inverse of `ListPane`, and the shape of the Issues and
  PR mocks. `Screen::sidebar()` and `Screen::on_sidebar()` are the second pair;
  split in two rather than passed a region so a screen cannot read an index
  against the wrong list, which is the one mistake here that would act on a row
  nobody was looking at.

  **`l` opens what it can and crosses when it cannot**, which is the same edge
  rule as everywhere else and is load-bearing here: every row in the PR sidebar
  is a dropdown, so without the second half `l` toggled dropdowns forever and
  the list was unreachable. An open control has nothing left to open, so `l`
  moves on.

  `draw_rows` measures `indent` from the region's `x0`. It did not for one
  commit and the main list drew straight over the sidebar.

- **Forward EVERYTHING from `Host` that a screen says about itself.** This has
  now been got wrong THREE times in the same way — `split()`, then
  `sidebar()`, then `answered()` — and none of them looked like a forwarding
  bug from the symptom: a table with no names in it, an empty left column, and
  a question that opened a field, took the text, and did nothing with it.

  The rule is now stated on the trait itself, in `screen.rs`: **a method with a
  default body is a method `Host` has to forward.** The default is exactly what
  makes these quiet — a host answering for it compiles and runs. The required
  methods are safe, because a host missing one would not build.
  `host::tests::everything_comes_from_the_active_tab` covers the whole set
  rather than the method that broke, and adding a defaulted method to `Screen`
  means adding a line to it in the same change.

  The third one took a while to see because `Menu` had been the only thing that
  asked, and a `Menu` is PUSHED rather than hosted — so `Flow::Ask` worked
  everywhere it had been used, right up to the first hosted screen that asked
  for itself.

- **`Screen::split()` picks the layout, per screen.** `ListPane` (the default),
  `Full`, or `Sidebar`. The shapes genuinely differ: a workflow run is a short list with a
  long story beside it, where a branch list is a TABLE — seven facts per row
  and nothing a pane could add. A `Full` screen is never asked for a pane at
  all, so it need not implement one usefully.

  **`Host` must FORWARD it**, because the layout belongs to the tab rather than
  the strip above it. Forgetting that made `Split::Full` silently do nothing:
  the host answered for the default and the table's badges, packed into a
  52-column sidebar, truncated every branch name to nothing. There is a test.

- **`Row::badges` is a VEC, and it does not self-align.** One badge could only
  hold the last of a table's seven columns. `app` packs them against the right
  edge, rightmost last so a screen listing them in reading order gets that
  order on screen — but it does not align them. A screen that wants COLUMNS
  pads each value to a fixed width itself, because it knows its own data and
  `rows()` deliberately does not know the terminal width.

- **No emoji in a fixed-width column, and the branch marker is where that bit.**
  The design asks for a lock glyph on protected branches. `U+1F512` is East
  Asian Wide — two cells in wezterm, one in terminals that disagree — in the one
  column whose entire job is being fixed-width. `★` and `●` are single-width
  and already used here; protection is a `prot` text column on the right.
  `branches::tests::the_marker_column_is_fixed_width` asserts every marker is
  inside the BMP, and it also counts the prefix in CHARACTERS rather than
  bytes: `str::find` returns a byte offset and `★` is three bytes, so the byte
  version failed on a perfectly aligned row and would have passed on a broken
  one whose counts cancelled.

- **Every control is a dropdown, and bulk actions are a menu.** The PR mock
  draws state toggles, a sort order and a search in a header strip and five
  filters down the side. They are all the same thing — a named thing you open,
  pick from and close — so they are all sidebar rows, one control per row, and
  `enter` means exactly one thing. A header row holding four controls side by
  side would need column focus inside a row, which is the axis this does not
  have.

  `space` ticks a pull request, the key that toggles a section in `dots`. With
  anything ticked the list grows a row saying how many, and `enter` on it opens
  a `Menu` whose items act on the set — so bulk actions cost no new region and
  no new keys, and inherit the confirm.

  **Ticks are kept by NUMBER and dropdown picks by NAME**, never by position. A
  refresh reorders the list and grows the option lists, and a `Vec<bool>`
  indexed by position would silently move a tick onto a different pull request
  or a filter onto a different person.

  Only `state` refetches, because it is the only control that changes which
  pull requests EXIST. Author, assignee, involvement, labels, sort and the `/`
  search are all applied to the fifty that came back.

- **`enter` on a row opens that row's MENU, and that is the design's
  three-dots.** It needs nothing from `reticle` — a menu is a list of rows and
  `Flow::Push` opens it. What it avoids is the only expensive part of drawing
  buttons on a row: putting the cursor ON one needs column-wise focus, a second
  navigation axis, and it collides with `h`/`l` meaning close/open everywhere
  else. The bash implementation already worked this way (thirteen actions on a
  PR row, seven on a branch), so this is the shape being ported.

  **Most items are `Flow::Detach`, and that is the finding worth keeping.**
  `gh pr create` prompts for a title and body on a tty; `gh pr edit` prompts for
  what to change; `git push --delete` prints what it did and fails loudly on a
  protected branch. Handing them the real terminal buys text entry,
  confirmation and error reporting in the tools' own words — so full
  functionality does NOT wait on a text-input widget. Showing the command in
  the pane IS the confirmation; a destructive item is marked in the row, the
  pane and the footer, and adds no prompt of its own, because the tool already
  asks or already reports and two confirms is one too many.

- **A long command WRAPS in the menu pane; it does not get truncated.**
  `argv.join(" ")` was fine while every item was `gh pr merge 86 --repo x`. An
  environment PUT carries the whole environment and comes to three hundred
  characters, which the pane cut off — and a confirm you cannot read all of is
  not a confirm, since showing the command IS the confirmation here.
  `menu::wrap_argv` breaks it at argument boundaries and keeps a flag with the
  value after it, because `-F` on one line and `reviewers[][id]=7` on the next
  reads as two things.

- **Every environment change sends the WHOLE environment.** `PUT
  /repos/{owner}/{repo}/environments/{name}` is "create or update", and the
  documentation does not say what happens to a parameter you leave out
  (checked, not assumed). The bash version sent `{wait_timer: n}` alone, so IF
  omission clears, setting a wait timer silently dropped the required reviewers
  — and nobody would find out until a deploy that should have waited for an
  approval did not.

  Sending everything makes the question moot: whatever the semantics, the
  environment afterwards is what the pane showed plus the one change. It costs
  nothing, because `gh api`'s field syntax carries all of it with no shell and
  no temp file: `-F 'reviewers[][type]=User' -F 'reviewers[][id]=123'` builds
  an array of objects, one per pair, in order; `-F 'reviewers[]'` sends an
  empty array; `-F key[sub]=value` nests; `-F x=null` sends a real null. All
  four were verified against `gh api --verbose` against a path that could not
  create anything, before any of the screen was written.

- **Required reviewers get a PICKER because the API takes an id.** No amount of
  typing produces a numeric user id, and the collaborators endpoint hands back
  logins with theirs — so a list to tick is both nicer than a field and the
  only shape that can work. It also matches the semantics: the field is a SET
  the PUT replaces wholesale, so it opens pre-ticked with whoever is required
  now, and whoever is required is a candidate whether or not they are a
  collaborator. A team never will be, and an outside reviewer would otherwise
  vanish from the list that replaces them.

  When the collaborators call fails — it needs push, which you do not have on
  someone else's repo — the error is said out loud EVEN THOUGH there are rows,
  because the rows are then only the already-required ones. A short list that
  looks like the whole list is the one way this screen could mislead.

- **A secret's value never enters this process, and no field here could
  improve on that.** `gh secret set NAME` reads it from the terminal with echo
  off and encrypts it locally before it leaves the machine, so `Flow::Detach`
  means the value is never in a `String` here and cannot end up in a redraw.
  The NAME is asked for, because gh takes that as an argument.

  It is passed **as typed**, not upper-cased the way the bash version did:
  GitHub treats secret names case-insensitively, so that was a convention
  rather than a requirement, and silently rewriting what someone typed is not a
  thing to do on their behalf. What IS checked here is the part GitHub will
  refuse — the character set and the reserved `GITHUB_` prefix — because
  learning that from a round trip means typing a name, handing over the
  terminal, typing a value, and only then being told.

- **The scope of a new secret comes from the GROUP the cursor is in.** The
  Secrets screen is the repository's secrets and each environment's as groups,
  so `+ new secret in staging` lives inside the staging group and there is no
  dialog asking where it should live — where the fzf version opened a "Where
  does it live?" menu first. Navigate, do not ask. The groups also mean `/`
  narrows across every scope at once, which answers the question you actually
  arrive with: is `DEPLOY_TOKEN` set anywhere.

- **The Branches table is local git first.** One `for-each-ref` gives every
  remote branch's age, author, subject AND ahead/behind against the default —
  offline, instantly, in one spawn. The API is asked only for what git cannot
  know: `protected`, open PRs, and checks. So the table draws before any
  request is made. `%(ahead-behind:)` needs git >= 2.41 and an unsupported atom
  fails the WHOLE command, so the fallback re-runs without it rather than
  trying to salvage a partial answer.

  **Checks cost no extra call**: a run carries its `head_branch`, so the newest
  run per branch is that branch's status, and the repo `Host` shares one
  `Fetcher` across its tabs so Branches reuses what Actions asked for.

  **"Your branches" matches on EMAIL.** Measured here: the same person authored
  commits as both `Riley Oest` and `roest1` — a local `user.name` and GitHub's
  web UI disagreeing — while the email was identical on every one. Matching the
  name filed your own branches under someone else.

- **There is ONE root, and it is the user level — including inside a repo.**
  This is the whole answer to "I want my settings even when I opened this in a
  repo", and it is a rejection of the obvious design. Opening at the repo level
  when you are in a repo and the user level when you are not gives you TWO
  roots, and two roots cannot connect: with the repo as the root there is
  nothing above it to walk up to.

  So standing in a repo seeds the SELECTION, not the root. `github` in a repo
  opens the user level on its Repos tab with that repo selected; `q` walks up
  from a workflow run to the repo list to the account and quits there. Do not
  add a "jump to settings" key — the stack already expresses it, and a jump
  would be a second spelling of one thing.

- **Tabs are for siblings; the stack is for drilling in.** `reticle::Host` owns
  one `Screen` per tab and forwards to the active one, so a screen does not
  know it became a tab — `Actions` was written before tabs existed and is a tab
  now, unchanged. `Tab`/shift-`Tab` move along; `Flow::Push` from inside a tab
  opens over the WHOLE host and `q` returns to the tab you left.

  Six things about one repo are not six levels deep. A stack would make Issues
  → PRs a pop and a push through a hub that exists only to be passed through.

  **A one-tab strip is a title that cost a row**, so a level gets a `Host` only
  once it has two real screens. The user level has four and an org has three;
  the REPO level has one ported of six designed, so enter on a repo still
  pushes `Actions` directly. It becomes a `Host` in the commit that adds the
  second repo screen, and nothing else changes.

- **`Host` remembers each tab's cursor, and `Flow::Retarget` is how.** A tab
  switch replaces every row, so `app` cannot carry the selection across —
  clamping a 40-row position into a 3-row tab lands somewhere arbitrary.
  `Retarget` makes `app` re-ask `initial_sel`, which the host answers with the
  mark it saved on the way out. `app` never learns what a tab is.

- **The pane does not reserve an image region it has no image for.** It used
  to, unconditionally, which pushed every TEXT-ONLY pane to the bottom of the
  screen under a rule that separated nothing from nothing. Invisible while the
  only screen here was `font`'s specimen; wrong for `dots`, wrong for all of
  `github`. The rule is a SEPARATOR and appears only when there is something to
  separate. The image path's arithmetic is unchanged.

- **Scopes are read off the response, never tabulated.** Every GitHub reply
  carries `X-Oauth-Scopes` (what the token has) and `X-Accepted-Oauth-Scopes`
  (what the endpoint would accept, any one of them) — on FAILED replies too.
  So a denial names its own fix and there is no endpoint-to-scope table to
  drift. `gh api -i` on every call is what makes that free; the token's own
  scopes are learned from whatever request happened to run, so there is no
  startup probe and must not become one.

  **A 404 has to be translated.** `GET /user/keys` without the scope answers
  **404, not 403** — rendered literally that is "you have no SSH keys" on an
  account with two. `Got::Denied` is kept apart from `Got::Failed` for exactly
  this: one is "your token cannot see this, here is the line that changes
  that", the other is "something went wrong".

  **It suggests the NARROWEST accepted scope.** Offered
  `admin:public_key, read:public_key, write:public_key`, it says
  `read:public_key`. `gh`'s own message suggests `admin:` because it cannot
  know what the caller intends; this screen only reads. Writing keys asks for
  `write:` when it exists.

  Enter on the denied row RUNS the fix via `Flow::Detach` — `gh auth refresh`
  is interactive and needs the real tty, and it is self-confirming because gh
  says what it is about to do and waits. The screen then re-asks on the next
  tick, via a flag rather than before the detach: the detach is what changes
  the token, so a request fired beforehand races it and comes back denied,
  which looks exactly like the authorisation having failed.

- **Tokens and 2FA are said out loud, not shown as empty lists.** Neither has
  an API at any scope. A blank list reads as "none" and would be wrong, so the
  Account tab names them as unreachable instead. Absent information and absent
  data are different claims.

- **There is no Enterprise level, and that was measured rather than assumed.**
  Every org on this account is free or team plan and the token has no
  `read:enterprise`, so GraphQL refuses `viewer.enterprises` outright. A screen
  for something that cannot exist is maintenance for nothing. If one ever
  appears it is a level above `orgs` and the seeded stack already takes it.

- **`github` builds but does not install, and that is the whole plan.** A bash
  function beats PATH and `github()` is still defined in `bash_github_tui`, so
  a `github` binary installed now could not win anyway. It is therefore absent
  from `deps.conf` and `tui/deps.sh` until the commit that deletes the bash
  function adds it to both. Develop with `cargo run -p github`. Do NOT wire up
  a half-ported `github` that dispatches to both halves; replacing that file as
  a unit is exactly what the CI rule "only bash_github_tui may invoke fzf" was
  built to allow.

  **The precondition for the swap is a table, not a judgement.**
  [`docs/decisions/github-parity.md`](../docs/decisions/github-parity.md) has a
  row per `_ghw_main` verb, DERIVED from the dispatcher so a verb cannot be
  silently absent, and CI blocks `github` entering `tui/deps.sh`'s `crates=()`
  while any row is `todo` or `partial`. Both directions are asserted. The
  statuses are a measurement except `dropped`, which is a decision and needs an
  argument in the row.

  **The `No bash function shadows a tui binary` CI row is RED for the duration
  of the port, and that is the forcing function it was written to be.** It
  derives the binary names from `tui/Cargo.toml`'s `members`, so adding
  `tui/github/` to the workspace — which building and testing it requires —
  starts it covering `github` while `github()` still exists. Its own comment
  predicted this: *"fails until the bash function is gone, which is exactly the
  handover it should force."* Do not narrow it to the installed set to get a
  green tick; the red row is the deadline. It goes green in the commit that
  deletes the bash function.

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

  **`app` asks PUSHED screens too, and that was a bug for one commit.** The
  push path hard-coded `sel: 0`, which was invisible for as long as nothing
  overrode `initial_sel` and then silently wrong for the first screen that did:
  drilling into a failed run opened on the run's first job instead of on the
  step that failed. Both paths go through `start_sel` now.

- **`Tick::Wake(Duration)` is the third clock, and it exists because `Busy` is
  a FRAME clock.** `Busy` means "look again next frame", which is right for
  work that lands in milliseconds — the font browser rasterising a specimen —
  and wrong for a network round trip. A nine-minute workflow run reported as
  `Busy` would spin the process at 60fps for nine minutes to notice an event
  that can only arrive on a five-second boundary: the laptop fan `app`'s
  blocking poll exists to avoid, reintroduced by the one screen that most needs
  to stay quiet while it waits.

  So the SCREEN picks the clock, because the screen is what knows which kind of
  work it started. `Wake` is a floor on how long `app` may sleep, never a
  ceiling on how often it may draw — an animating reticle still outranks it, or
  a refresh would make the brackets stutter. `app::tests::a_slow_clock_does_not_become_a_frame_loop`
  pins all three orderings, and the measured result is the point: the Actions
  screen emits **zero bytes** over twenty idle seconds on a repo whose runs have
  all finished.

- **The Actions screen runs TWO clocks, and both stop by themselves.** The list
  is re-asked every 15s, the selected run's jobs every 5s — each only while the
  thing it is watching is unfinished, and each re-armed from what ARRIVED
  rather than on a fixed timer. A list of completed runs schedules nothing, so
  there is no stop button to find and no timer left running behind a cursor
  that has moved on. The jobs clock follows the CURSOR, which is the half most
  easily got wrong: visiting five runs during a build must not leave five
  timers behind.

- **A toggle that cannot come back is not a toggle.** The Actions screen is
  reachable two ways — the repo's 🚀 tab, and the pull request menu's "Workflow
  runs for this commit", which is bash's `ctrl-a` as a row — and `b` offers a
  DIFFERENT pair in each. Opened on a repo it is every branch or the one checked
  out here. Opened on a commit it is that commit or the branch carrying it,
  because widening a commit scope to every branch is a door that does not come
  back: nothing on screen afterwards names the commit again, so the only route
  to it is `q` out and open the menu a second time.

  So `Actions` remembers the commit it was OPENED for, separately from the
  scope `b` has got to since. `scope` is where you are; `commit` is what the
  screen is about, and the second is what makes the first reversible.

  `for_commit` takes a slug and a sha rather than an `index::Repo`, which is
  the whole reason a second constructor had to exist: a pull request's head
  commit need not be anywhere on this disk — a fork, or a branch this clone has
  never fetched — so there is no `git rev-parse` to do and nothing local to
  read. It is handed the pull request screen's own fetcher, which is the same
  repo, so a completed run's jobs and logs come from what the Actions tab
  already has.

  **The HEAD marker switches off inside a commit scope**, because there every
  run IS that commit and a dot on every row says nothing. Widen to the branch
  and it comes back, now answering the question you actually have: which of
  this branch's runs belong to the commit I came from.

  **Inside a commit the row is the WORKFLOW and its run number, not the run
  title.** Every run of one commit carries the same `display_title` — the pull
  request's — so a list of titles is a column of identical rows; the first
  real repo this was pointed at drew five. The workflow is what identifies a
  row there, with the number because a workflow can run several times on one
  commit (three `pull_request_target` runs of the same workflow, measured), and
  it goes in the LABEL rather than the detail because the detail is the first
  thing a 52-column list truncates away. Spelt as the pane's header spells it.

- **A scope toggle has to RE-READ what the fetcher already has.** `Actions::tick`
  syncs when the fetcher's epoch moves, which is the right rule for an arrival
  and the wrong one for a toggle: switching back to a scope answered a moment
  ago makes nothing arrive, so the screen sat on an empty list saying "no
  workflow runs here yet" about a scope with six runs in it. `toggle_scope`
  calls `sync()` itself now.

  Worth keeping because of how it hid. A live run re-arms the list clock and
  that refresh DOES bump the epoch, so on any repo with something building the
  list reappeared a second later and the bug was invisible. It only showed on a
  scope where everything had finished — which is every commit scope on a pull
  request that has stopped moving, i.e. most of them.

  `Fetcher::seed` exists for this, `#[cfg(test)]` only: `request` reaches the
  network and `get` is the only way back out, so how a screen behaves on an
  answer it ALREADY HAS was otherwise untestable. It deliberately does not bump
  the epoch — that is the condition being tested, not a quirk of the seam.

- **Only what cannot change is cached across sessions.** A completed run's jobs
  and a completed job's log are immutable, so they live in
  `~/.cache/dotfiles-github/<owner>/<name>` and last week's failure opens
  instantly in a shell that has never seen it. A run LIST is a question about
  now and a live run's jobs are the thing being watched change, so neither
  touches the disk.

  **The cache key carries the ATTEMPT**, not just the run id. A rerun is the
  same id with entirely new jobs, so a key on id alone serves the previous
  attempt forever — which is why the bash implementation had to delete cache
  files on rerun. Putting the attempt in the key retired the deletion.

  **Whether an answer may be cached is the caller's claim, from the list it is
  already showing** (`Req::Jobs { persist }`), which saves the second `gh api`
  call the bash version made to ask a run its own status. That staleness is
  safe in only one direction and it is the one that matters: a 15-second-old
  list can say "running" about a run that just finished, and we merely decline
  to cache. It can never say "completed" about a run still going, because
  completed is terminal.

- **The pane DOES NOT SCROLL, and a log is the one thing whose end matters.**
  `draw_pane` cuts whatever does not fit and says nothing, so a four-hundred
  line body in a forty-row pane loses its own tail — which for a failed run is
  the summary and, worse, the error. This is easy to forget because every
  previous log view in this repo could scroll: fzf's preview took the mouse and
  a pager scrolls by definition, so "print it all" was always available before.
  It is not here.

  So `render::tail_budget` divides the room among the failed steps and each gets
  a TAIL, with a marker naming how much it hid and which key pages the rest.
  What survives a pane too small for everything is the STRUCTURE — the step
  names and the summary — because those answer "is it green" and "which step",
  and a tail of four lines answers neither.
  `render::tests::a_body_never_outgrows_the_pane_it_was_given` asserts the fit
  at five pane heights; the first draft showed the runner installing chromium
  and hid the assertion that failed.

- **The step-log slicing is ported line for line, and its tests came first.**
  GitHub serves no per-step logs — the archive is one file per job, which is
  why `gh run view --log` prints `UNKNOWN STEP` — so a step's output is
  reconstructed: a timestamp window, then the step's own `##[group]Run` line as
  an anchor, then a cut at the last `##[error]`. The anchor PREFERS a group
  whose text is the step's name, which is what makes unnamed `uses:` steps work
  and what stops a window that opened a second early from returning the
  previous step's output.

  Tests before implementation here alone, and the reason is the failure mode
  rather than the difficulty: a slice off by one boundary returns plausible log
  output for the wrong step, and nothing about the result looks wrong. It
  compares timestamps as STRINGS, as the awk original does — fixed-width ISO
  8601 sorts lexicographically, so parsing them into instants would be slower
  and no more correct.

- **Status words, not emoji, in a `Row::badge`.** The badge is right-aligned
  into a fixed grid and an emoji is double-width in some terminals and single
  in others, so a column of them lines up nowhere reliably. `ok`/`fail`/`run`
  with a colour index does. The PANE is free prose and keeps the glyphs.

- **One `Verdict`, derived in one place.** `status` and `conclusion` together
  have more states than anyone needs to reason about, and reasoning about them
  per call site is what let the bash renderers drift on which field decided a
  job's colour. Both unknown-state directions fail safe deliberately: a
  conclusion GitHub adds later reads as `Other` rather than as a failure, and a
  STATUS it adds later reads as running rather than as finished — because a run
  wrongly called finished stops being polled, which is the error that does not
  correct itself.

- **`github`'s confirm is screen-local and safe by construction, not by
  bookkeeping.** `e` and `x` cost runner minutes or kill a build, so they ask;
  the only key that acts is `y`, and any other key the screen sees — plus any
  cursor movement, via `focus` — withdraws. That is deliberately weaker than a
  real dialog: a shared confirm WITH text entry is still the right home, since
  `pr-create`, `secret-set` and every delete need one, and that is a `reticle`
  change rather than five screen-local copies of this.

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
