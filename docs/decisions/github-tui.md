# The GitHub TUI

**Status:** active. `gh-tui` is the single entry point.
**Code:** `bash/bash_github_tui`

## What exists

`gh-tui` is a hub with a live preview pane. Five screens hang off it — Pull
Requests, CI/Actions, Secrets, Branches, Environments — reached through the hub
rather than as separate commands. `gh-ui` is an alias for `gh-tui`.

Press `?` in any screen for that screen's help.

## The question that was open, and how it resolved

Shell history recorded zero uses of the five screens, which read at first like a
verdict: replace it with [forgit](https://github.com/wfxr/forgit) or
[neogit](https://github.com/NeogitOrg/neogit).

It isn't. Both are git-only. Neither touches the GitHub API, so Secrets,
Branches/rulesets and Environments have no equivalent in either — the closest
thing to a competitor for the PR screen specifically is
[octo.nvim](https://github.com/pwntester/octo.nvim). And neither tool had been
tried, so the zero measures habit, not preference.

So the work became *make it worth reaching for* rather than *replace or keep*.
Three things were in the way, all now fixed:

**It stalled.** The hub re-ran an 8-call prefetch on every menu render, because
navigation was a tail call back into `gh-tui`. A `gh` round trip is ~0.34s, so
backing out of a screen cost about a second of refetching data it already had —
on the screen you pass through most. The prefetch now runs once per session;
`r` refreshes it.

**The stack grew as you used it.** Every menu was tail-recursive: `gh-tui`
called itself, `_gpr_actions` had 12 self-calls, `ghsecrets` 8. Six menus are
now `while` loops. Measured: stack depth is constant at 3 across renders, where
it previously climbed by one per navigation.

**It didn't explain itself.** 174 of `h`'s 471 lines documented these screens
from another file, reachable only if you already knew to type `h gh-tui`. That
help now lives in the screens behind `?`, and `h` is 333 lines.

## Conventions this file follows

- **Only this file may invoke fzf.** `bash_git` is git porcelain, `bash_github`
  is plain `gh` plus shared helpers, this is everything interactive. CI checks
  it. That boundary is what keeps this layer replaceable as a unit.
- **`gh-tui` is the only public function here.** CI checks that too.
- **`__` is a helper shared across files, `_` is private to this one.** CI
  rejects a `__` name defined here.
- **Menus and lists go through `__fzf_menu` / `__fzf_list`** in
  `bash_productivity`, which own the keybindings and the header hint. Seven fzf
  calls remain hand-written where they genuinely differ (multi-select, preview
  windows); the other 27 do not.

## Still open

- **Clickable arrows and X close buttons.** fzf can bind mouse events. It cuts
  against the nvim-like keyboard contract, so it should be a deliberate
  decision rather than something that accretes.
- **forgit's previews.** Its diff/add/checkout previews are better than these
  and worth reading regardless of whether it gets adopted.
- **Demos.** `git/GITHUB_TOOLS.md` carried nine `asciinema.org/a/XXXXXX`
  placeholders and a recording guide through several refactors without a single
  recording being made. Both are gone; the walkthrough prose stayed. Recording
  is worth revisiting once the screens stop moving — `vhs` is the modern
  single-binary option and, unlike asciinema or terminalizer, needs no Python
  or node.
