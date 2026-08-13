# The GitHub TUI

**Status:** working and parked. Next thing to work on, not the current one.
**Code:** `bash/bash_github_tui` (~1,800 lines)
**Blocked on:** one decision, below.

## What exists

`gh-tui` is a unified hub with a live preview pane. Five screens hang off it,
each also callable directly for now:

| command     | screen                                            |
|-------------|---------------------------------------------------|
| `gpr`       | PR list → pick → act (merge, review, labels, …)   |
| `gha-ui`    | workflow picker → action menu → smart log view    |
| `ghsecrets` | repo and environment secrets                      |
| `ghbranch`  | branches and rulesets, with effective-rule view   |
| `ghenv`     | environments, reviewers, wait timers              |

`gh-ui` remains as an alias for `gh-tui`. The name was renamed *to* `gh-tui`
because that is what this file's header and `h` had both been advertising while
the function was actually called `gh-ui` — the documented command did not exist
and the real one was undocumented.

## The three-file split

`bash_git` (git porcelain) → `bash_github` (plain `gh`, shared helpers) →
`bash_github_tui` (everything interactive), sourced in that order.

The rule that makes it real: **only this file may invoke fzf**, and CI checks
it. That is not tidiness. It is what lets this entire layer be replaced or
deleted as a unit without touching the two files below it, which matters given
the open question.

## The open question, which gates everything else

**Where do you actually do git?**

Three implementations of "interactive git" are starred or installed:
[forgit](https://github.com/wfxr/forgit) (bash, fzf, maintained, 5k stars),
[neogit](https://github.com/NeogitOrg/neogit) (nvim, Magit-like), and this.
Shell history recorded **zero** uses of `gpr`, `ghsecrets`, `ghbranch`, `ghenv`
and `gha-ui`, against 8 for `gha` and 3 for `gh-ui`.

That is one machine's history and `HISTFILE` only flushes on exit, so it is a
signal and not a verdict. But it should be answered before more is built here:

- **"I type `git` and use the GitHub web UI"** → this layer is a deletion, and
  `bash_git` + `bash_github` already hold everything that gets used.
- **"In the editor"** → neogit replaces the git half; the GitHub API screens
  (`ghsecrets`, `ghbranch`, `ghenv`) have no neovim equivalent and stay.
- **"In the terminal, I just never built the habit"** → forgit is the
  maintained version of the git half. The GitHub screens remain genuinely
  yours; forgit does not touch the GitHub API.

Worth noting that the GitHub API screens are the part with no off-the-shelf
competitor, and also the part with no recorded use. The `gha`/`gha-fail` pair,
which does get used, is already out of this file.

## Ideas to bring in

- **`__fzf_list` for the remaining screens.** 16 fzf calls are left here; 9 are
  the plain list shape and would convert directly. The 18 menu sites are done.
  The rest are genuinely special (multi-select, preview windows) and should
  stay hand-written.
- **forgit's patterns**, whatever the decision above. Its diff/add/checkout
  previews are better than these, and reading them costs nothing.
- **Clickable arrows and X close buttons.** Recorded from the original header
  so it isn't lost — fzf can bind mouse events, so this is possible, though it
  works against the nvim-like keyboard contract and should not quietly become
  the primary affordance.
- **A `?` key binding** that shows the current screen's help inline. This is
  where the GitHub half of `h` should end up: help for an interactive tool
  belongs in the tool, not in a heredoc in another file. Doing this deletes a
  large block of `h` rather than moving it.

## Things to change

- **`git/GITHUB_TOOLS.md` has nine demo placeholders**, every one still
  `asciinema.org/a/XXXXXX`, plus a recording guide. Demos were never recorded,
  for screens that have never been used. If the layer is cut, that file and the
  recording guide go with it. If it stays, record them or delete the
  placeholders — an unfilled template reads as neglect either way.
- **`_gha_*` and `_gpr_*` helpers use single-underscore prefixes** while the
  shared ones in `bash_github` use double. Nothing depends on the distinction;
  pick one when this file is next opened properly.

## Why it is parked rather than cut

It works, it is isolated behind an enforced boundary, and it is ~1,800 lines
that would be tedious to rewrite and trivial to delete. Deleting it is a
one-line change to `deps.conf` plus one `git rm` on the day the question above
is answered. Until then, keeping it costs a `source` of a file that parses in
milliseconds and is covered by CI like everything else.
