# The GitHub TUI

**Status:** active. `github` is the single entry point.

**Renamed from `gh-tui`** (2026-08-24). The name moved ahead of the
implementation on purpose: this is planned to become a `reticle` crate
alongside `font`, and renaming at the rewrite would have cost two flag days of
muscle memory instead of one. The command you type is now stable across the
port; what runs underneath is not.

Two names deliberately did NOT move with it. The file is still
`bash/bash_github_tui`, because it is named for its role — the interactive
layer of the github commands — and that is still what it is. The wezterm
user-var is still `gh_tui`, because it is a WIRE name: bash writes it in the
WSL guest and `wezterm/shared.lua` reads it on the Windows host, out of a
separate clone, so renaming it leaves the tab mark dark until `make windows`
has pulled the other side. Neither is typed by anyone.
**Code:** `bash/bash_github_tui` · **Walkthrough:** `git/GITHUB_TOOLS.md`

## What it is

One TUI for the current repo on GitHub: Actions, Pull Requests, Branches,
Secrets, Environments. Every screen is one fzf window — a list on the left, a
live preview on the right, single-key actions on the list. `ctrl-/` in a list
or `?` in a menu shows that screen's help.

## The problem the rewrite solved

The previous version worked and was parked (August 2026, `f80d132`), and the
open question was whether it was worth reaching for. Using it answered that:
it wasn't, for three reasons that turned out to be one.

**Every screen stopped to open the next.** Actions was scope picker → run
picker → action menu → *then* the logs. Each hop was a fresh fzf with a fresh
fetch in front of it, so looking at a failing step cost four screens and a
few seconds of "⏳ Fetching…", and coming back re-ran the list from the top.
The pagers ended with `read -rsn1 "r=refresh -/q=back"` — a screen that asks
you to press a key to leave is a screen that has stopped.

**The previews were `echo {}`.** The run list's preview was the raw line —
tab-separated ids and URLs — because the data a preview needs was fetched
*after* you picked, not while you looked.

**It didn't look like anything.** Plain `--header` strings, no colour on the
list rows, no glyphs past the status one.

All three are the same fault: the fetch happened between screens instead of
under the cursor. So the rewrite moved it.

## How it is built now

**Screens open instantly and fill in.** Nothing is fetched before fzf starts.
The list arrives through a `start:reload` binding; the preview is rendered
per item and cached; the hub's five panes are prefetched in parallel behind
the menu and each POSTs a `refresh-preview` as it lands.

**Live, not refreshable.** Every screen runs fzf with `--listen`, which hands
its child commands an `FZF_PORT`. A preview that renders something still in
progress — a running workflow, a PR with pending checks — schedules one POST
a few seconds out (`_ghw_tick`, one timer per fzf instance, so ten hovers
don't stack ten). When it fires the preview re-renders and, if still running,
schedules the next; when the run completes, the preview also reloads the list
so the ⏳ becomes ✅ without a keypress. `ctrl-r` still exists; it is rarely
needed.

**Back is back.** A screen opens *inside* the one below it: `enter` is
`execute(bash $W screen-steps {2})`, a nested fzf, so the parent fzf is still
running underneath with its cursor, filter and scroll, and `esc` returns to
exactly that. There are no menu loops that "return you to the hub" by
restarting it. This is what fixed the stop-and-reopen feel more than anything
else.

**One worker script, `declare -f`'d.** fzf's preview/reload/execute commands
run in a child shell with none of the parent's functions. Rather than
materialise each renderer as a file, `github` writes ONE script per session:
the session facts (`$D`, `$R`, `$CACHE`), then every `_gh*` function in the
file printed with `declare -f`, then a dispatcher. Every fzf command is
`bash $W verb args…`. So a preview is an ordinary bash function in the same
file — shellchecked, sourced, greppable — and there is no second copy to
drift. The cost is a rule: a `_ghw_` function may call other `_ghw_`
functions, the chrome helpers, `_open_url`, and bash_theme's time helpers,
and nothing else from the parent shell.

**Logs come per job and are sliced per step.** GitHub serves one log per job
(`/actions/jobs/{id}/logs`, ~15KB, half a second) where the run log is
megabytes and seconds. Per-step logs no longer exist anywhere: the run zip
stopped carrying per-step files, which is why `gh run view --log` now prints
`UNKNOWN STEP`. So a step's lines are reconstructed — its `[started,
completed]` timestamp window (second precision, too coarse for sub-second
steps on its own), anchored on the step's own `##[group]Run …` marker and cut
at the last `##[error]` before the next step's marker. Exact for `run:` and
`uses:` steps; the runner's own Set up / Post / Complete steps get their
whole window. Verified against a real failure where the naive window
returned checkout cleanup instead of the `make` error.

**Immutable things are cached across sessions.** Rendered bodies of completed
runs and logs of completed jobs go under `~/.cache/github/<owner>/<repo>/`,
pruned at 14 days. A rerun invalidates (it is a new attempt of the same id).

**One palette, one chrome.** The eight colours the prompt uses (bash_theme),
`--style=full:rounded`, a border label per screen, a list label for the
current filter, a footer for the keys. Menus still go through `__fzf_menu`
(bash_productivity), which owns the `-`/`q`/`?` contract; they get the same
chrome by appending the style array. `_gh_confirm` and `_gh_input` are fzf
too — a y/N or a name prompt looks like every other screen instead of a bare
`read` under it.

## What it cost

**fzf ≥ 0.65.** `--listen` (0.36), the `start`/`focus` events (0.36),
`transform-*` (0.45), `--style` (0.60), `--footer` (0.65). Ubuntu's apt has
0.29 (22.04) and 0.44 (24.04). So `deps.conf` moved fzf to `mise||pkg` — the
same call, for the same reason, as nvim — and `bash/deps.sh` enforces the
floor over an already-installed distro fzf, upgrading through the distro if
that reaches it and via mise if not. `github` checks the floor itself and
refuses with the same instruction. The shell's other fzf uses (Ctrl+R/T, the
menus in bash_productivity) run on any version.

**A live run costs one API call per five seconds while you look at it**, two
when it has failed jobs whose logs haven't been fetched. Nowhere near the
5000/hour limit; noted so nobody adds a second timer.

## Conventions this file follows

- **Only this file may invoke fzf.** CI checks it; the boundary is what
  keeps the interactive layer replaceable as a unit.
- **`github` is the only public function.** CI checks that too.
- **`__` is shared across files, `_` is private to this one.** CI rejects a
  `__` name defined here.
- **Menus go through `__fzf_menu`.** CI rejects a hand-rolled `--disabled`.
- **`h` names `github` and nothing else from here.** Every screen is `_`- or
  `_ghw_`-prefixed, so the help check doesn't demand entries for things you
  can't type.

## The port to `reticle`

Decided 2026-08-25, before any code. The three things below are the ones that
are expensive to retrofit; everything else stays deferrable.

**Account-rooted, not repo-rooted.** Today `__gh_repo` is `gh repo view` in
the cwd and every screen inherits that ambient `$R`. The target is a
hierarchy — your orgs, an org's repos and settings, then a repo's screens —
because the goal is not visiting github.com for anything done weekly. Adding a
root screen later is cheap; threading scope through 85 `gh` call sites written
against ambient state is not. So scope is settled first.

**`~/github/` is the index.** Reading it gives an instant, offline root list of
the repos actually cared about — a better default than everything the account
can see — with live data filling in after, the same way screens already open
before their data arrives. Repos not cloned come from the API below the fold
and clone into the matching slot.

The tree was measured before the reader was written, and the obvious design —
parse `~/github/<org>/<repo>` — is wrong on this machine four ways: the
directory `orgs/codegig` holds the org `codegig-br`; depth is not fixed
(`orgs/codegig/clients/shell/atlas`); some clones are other people's
(`bilawalsidhu`, `yt-dlp`); one has no remote at all. So the path gives
GROUPING and the remote gives IDENTITY, and neither can give both. Details in
`tui/github/src/index.rs`.

**One command, no flags, seeded selection.** `github` inside a repo does not
open the repo hub *as* root; root stays underneath, so `q` walks up rather than
quitting out of context. A flag or a mode would have made the root unreachable
from inside a repo.

The org level is a GROUP inside root today, not a screen — there is no
org-level data yet to put on one. When there is (settings, teams, members) it
becomes a screen and the seeded stack is `[root, org, repo]`; until then it is
`[root]` with the repo's row selected, and `[root, repo]` once repo screens
exist. `app::run_stack` already takes the stack, and `Screen::initial_sel` is
how a screen says which row to open on — asked of the screen because only it
knows where its own rows landed.

Two properties this depends on: screens must fetch on entry or focus, or
seeding the stack would fetch lists that get skipped past and make the repo
case slower than today; and "am I in a repo" must be answered offline (walk up
for `.git`, or test cwd against `~/github/`), not with `gh repo view`.

### Sequencing

Root screen first — it is new work rather than a port, it is small, and it
says whether the list-and-pane shape survives a repo list before 2500 lines
are rewritten. A repo list from local clones is also short enough not to need
filtering, which defers the one open framework question. Then Actions, which
is the only screen exercising live refresh, cross-session caching and the step
slicing at once; if that survives, the rest is mechanical.

**The bash file is replaced as a unit, not incrementally.** It stays complete
and untouched until the Rust side covers what is actually used, then it is
deleted in one commit. A `github` dispatching to both halves is the drift this
repo keeps deleting, and the CI rule that only this file may invoke fzf is
what makes replacing it wholesale possible.

**The binary keeps shelling out to `gh`.** Auth, enterprise hosts and token
refresh are solved, and `gh api` returns JSON for serde. Going direct buys
nothing and costs an auth implementation.

**Name collision, until the swap.** A bash function beats PATH, so a `github`
binary cannot be installed while `github()` is defined here — CI asserts it.
The crate builds under `cargo run` and is absent from `deps.conf` and
`tui/deps.sh` until the commit that deletes the bash function adds it to both.

### What the port deletes rather than translates

Roughly half this file exists to work around fzf, not to do GitHub work: the
`declare -f` worker script, its 25-verb dispatcher and its calling-convention
rule (fzf's children run in a fresh shell; a Rust preview is a method call);
`--listen`, `FZF_PORT`, the curl POST and the per-instance tick lock file
(`Tick::Busy`/`Changed` plus a worker thread — `font`'s `Fetcher` is the
reference); nested fzf (`Flow::Push`); and 67 jq programs (serde).

Port the step-log slicing with tests written first. It is the most hard-won
logic here and a subtle regression in it would look entirely plausible.

### Not being ported yet, and why

**Rulesets and permissions.** Not because the editor is menus-and-pauses where
the rest is list-and-preview — that was the old reason. The real one: they
have not been used enough to know what the screen should show. Porting
unvalidated behaviour preserves it bug-for-bug and lets it set the shape of
the screen. Use them on github.com first, then build the screen the use
produced. Same for **issues**, which nothing here has yet.

## Still open

- **Filtering.** fzf gives fuzzy-filter-as-you-type for free; `reticle::nav`
  maps every bare char to `Action::Key(c)`, which is what makes single-key
  actions work, so there is no text-entry mode to add it to. Needed by the
  long lists, not by the root screen. A modal state in `nav` is a change to
  the one file screens are told not to touch.
- **Text input and confirm.** `_gh_input` and `_gh_confirm` have no reticle
  equivalent; secret-set, env-create, pr-create and every delete need them.
  Framework-level and shared, so they land in `reticle` before the screens
  that need them.
- **Mouse.** fzf can bind mouse events. It cuts against the keyboard
  contract, so it should be a deliberate decision rather than accretion.
- **Demos.** `vhs` is the modern single-binary option; worth a recording now
  that the screens have stopped moving.
