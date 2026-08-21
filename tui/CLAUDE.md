# CLAUDE.md — `tui/`

## Overview

The Rust terminal UIs. One crate per screen, **one binary per command** —
`font` today, `github` and the `make it` console next. They share
`reticle/` and nothing else, because a font picker and a CI dashboard have
nothing else in common.

They are *not* modes of one program. `font` opens the font picker; `github`
will open gh-tui. That is the shape Riley asked for and it is also what keeps
each binary's startup honest.

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
- `font/` — two screens. `fonts` (discovery + measurement), `render`
  (rasterising, the contact sheet, glyph-distinctness), `lanes` (the
  machine-local `fonts.conf`), `fetch` (the prefetching cache behind
  `font browse`), `browse` (the Google-fonts screen), `main` (the picker).

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
- **`font inspect` is the one implementation of "measure a font".** `fontbrowse`
  (bash) calls it rather than carrying its own. The Python previewer that used
  to do this was deleted because the two had already drifted on which file
  counted as Regular.

## The command surface is three commands

`font`, `font show`, `font reset`. Everything else lives inside the TUI, which
states its own keys in the footer — including browsing, which is the last row
under an opened lane rather than a subcommand or a keybinding. A key you have
to be told about is a key nobody finds, and a subcommand is worse: it needs a
man page to discover something that could have been a row.

`app` keeps a screen STACK for this. `Flow::Push` opens one on top, `q` pops
below the root and quits at it, and each frame carries its own cursor, scroll
offset and reticle — so coming back lands on the row you left. That is the same
property gh-tui gets from running one fzf inside another, and it is the reason
gh-tui can move here without losing it.

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
