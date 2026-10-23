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

### What Actions actually cost (done 2026-10-22)

It survived, and the verdict stands: the remaining screens are lists with
previews over data this now knows how to fetch. What it cost that the plan did
not price:

**One framework addition, `Tick::Wake(Duration)`.** The plan assumed `Tick`
already covered live refresh — the enum's own header says `github` would need
"exactly this". It did not. `Busy` is a FRAME clock: it sets the poll timeout
to 16ms, which is right for the font browser rasterising a specimen and absurd
for a workflow run, where it would spin at 60fps for nine minutes to notice an
event that can only land on a five-second boundary. The screen is what knows
which kind of work it started, so the screen now picks the clock. Measured
after: zero bytes over twenty idle seconds, and entering the screen cost 76KB
instead of 285KB.

**One framework bug, found by being the first caller.** `app`'s push path
hard-coded `sel: 0` and never asked `Screen::initial_sel`. Invisible while
nothing overrode it; silently wrong the moment something did — drilling into a
failed run opened on the run's first job rather than on the step that failed.

**One thing the plan got backwards.** It assumed the port would carry the
fzf preview's "print it all" habit forward. It cannot: `reticle`'s pane does
not scroll, where fzf's preview took the mouse and a pager scrolls by
definition. A 400-line job log in a 40-row pane showed the runner installing
chromium and cut the assertion that failed, with nothing about the result
looking wrong. Every body is now budgeted against the pane height, structure
first and logs tailed, with `L` as the route to the whole thing. This is the
one place the Rust screen deliberately shows LESS than the bash one did.

**One API call deleted rather than ported.** The bash run body fetched the run
AND its jobs, because it needed the run's own status to decide whether the
rendered body was cacheable. The list already knows that, so the caller now
asserts it (`Req::Jobs { persist }`). The staleness is safe in one direction
only, and it is the right one: a 15-second-old list can say "running" about a
run that just finished and we merely decline to cache, but it can never say
"completed" about a run still going, because completed is terminal.

**The cache got simpler than the original.** Keying on `(run, attempt)` instead
of `run` retired the cache eviction that `_ghw_rerun` had to do by hand: a
rerun is now simply a key nothing has answered yet. And what is cached is the
JSON rather than the rendered body — rendering was a jq spawn in bash and is
microseconds here, so the cached artifact is data instead of presentation.

What the step slicing cost: nothing. It ported line for line, tests first as
planned, and worked against the real tree on the first run — it correctly cut
a `test` step out of a job log whose window also held an `apt-get` transcript,
anchored on the step's own `##[group]Run` line, and ended on the last
`##[error]`.

**The precondition is a table, and CI enforces it.**
[`github-parity.md`](github-parity.md) has one row per worker verb, derived
from `_ghw_main`'s dispatcher so it cannot be incomplete, and CI refuses to let
`github` into `tui/deps.sh` while any row is `todo` or `partial`. As of
2026-10-23: 22 ported, 2 partial, 24 todo, 1 dropped. The swap cannot be
reached by deciding it has been.

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

That CI row — `No bash function shadows a tui binary` — therefore **fails for
the whole duration of the port**, from the commit that added `tui/github/` to
the workspace until the one that deletes `github()`. It derives its binary list
from `tui/Cargo.toml`'s `members`, and its own comment chose this: *"fails until
the bash function is gone, which is exactly the handover it should force."* The
row is a deadline, not a defect. Do not narrow it to the installed set to get a
green tick — that would turn the forcing function back into the silence it was
written to replace.

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

## The user and org levels (done 2026-10-22)

Decided from Riley's `GITHUB_TUI.md` plus what the account actually permits,
measured before any of it was written. Three things the doc said changed.

**One root, not two.** The doc opened "at the repo level, and if not in a git
repo, at the user level". That is two roots, and two roots cannot connect — with
the repo as the root there is nothing above it to walk up to, so the "I want my
settings even when I opened this in a repo" the doc also asks for is
unreachable. Inverted: the user level is always the root, and standing in a repo
seeds the SELECTION. `q` now walks a workflow run → repo list → account. No new
mechanism; `app::run_stack` already did this.

**Tabs, because the design is a header strip over a sidebar and a pane, and
because `font`'s sidebar is the reference.** `reticle::Host` owns one `Screen`
per tab and forwards to the active one, which is what let `Actions` become a tab
without being touched. Tabs are siblings, the stack is depth, and a level earns
a strip only once it has two real screens — so the repo level is still a direct
push to Actions, with one of six screens ported. The bash hub was a list of five
rows, so the strip is a change from what exists rather than a continuation of
it; it is worth the framework row because the design asks for six repo screens
and popping through a hub to go sideways is two keystrokes for "along".

**No Enterprise level.** Measured: every org is free or team plan, and the token
lacks `read:enterprise`, so `viewer.enterprises` is refused outright. Cut rather
than stubbed. Orgs, by contrast, are fully reachable with the `read:org` this
token already has — members, teams and repos — so that is where the level went.

### Scopes, read off the wire

The doc wanted user settings: keys, credentials, integrations. Almost none of it
is reachable, and the reason is worth writing down because it is not obvious.

Every reply carries `X-Oauth-Scopes` and `X-Accepted-Oauth-Scopes`, on failures
as well as successes. The second is what the endpoint would have accepted — so a
denial names its own fix, and there is no endpoint-to-scope table in this repo to
go stale. The token's own scopes come from whatever request happened to run, so
learning them costs nothing.

Two things that had to be got right rather than merely working:

- **A 404 is not an empty list.** `GET /user/keys` without the scope answers 404,
  not 403. Rendered literally it says "you have no SSH keys" to someone with two.
  `Got::Denied` exists to stop that being possible.
- **Suggest the narrowest accepted scope.** `read:public_key`, not the
  `admin:public_key` that `gh`'s own message offers — gh cannot know the caller
  only reads, and this does. Creating keys is a later feature and asks for
  `write:` when it exists.

Enter on the denied row runs `gh auth refresh` through `Flow::Detach`, which is
the mechanism's natural end: the screen names what is missing and fixes it in
place. Tokens and 2FA have no API at any scope, so the Account tab says so in a
sentence rather than showing an empty list — absent information and absent data
are different claims.

### A framework bug the text-only screens had been living with

`draw_pane` reserved the inline-image region unconditionally, so a pane with no
image had its text pushed to the BOTTOM of the screen under a rule separating
nothing from nothing. Invisible while the only screen was `font`'s specimen;
wrong for `dots` and for every `github` pane including the Actions body shipped
in the previous commit. The image path's arithmetic is unchanged.

## Branches, `Split::Full`, and the three-dots (done 2026-10-22)

**Layout is per screen, option 1 of the three offered.** `Screen::split()`
returns `ListPane` (the default — `font`, `dots`, Actions, the account screens)
or `Full`. Branches is the reason: a branch row carries protection, when, who,
ahead/behind, the subject, its checks and its PR, and squeezing seven facts
into a 52-column sidebar beside a pane with nothing to say would have meant
dropping columns to make room for emptiness. Riley picked faithfulness to the
drawings over the cheaper single layout, with option 3 (one layout, per-screen
split width) held as the fallback if the per-tab version grates.

`Row` gained `badges: Vec<_>` for it. One badge could only hold the last of
seven columns. `app` packs them against the right edge and does NOT align them,
so a screen wanting a table pads each value to a fixed width itself — it knows
its own data, and `rows()` deliberately does not know the terminal width.

**Nearly all of the table is local git**, which is the bash implementation's
shape and worth preserving exactly: one `for-each-ref` gives every remote
branch's age, author, subject AND its ahead/behind against the default, offline
and instantly. The API is asked only for what git cannot know — `protected`,
open PRs, and checks. So the table draws before any request is made.

Two things measured rather than assumed:

- **Checks cost no extra call.** A workflow run carries its `head_branch`, so
  the newest run per branch IS that branch's check status — and `Req::Runs` is
  already fetched. The repo-level `Host` shares one `Fetcher` across its tabs,
  so Branches reuses what Actions asked for.
- **"Your branches" matches on EMAIL, not name.** On this repo the same person
  authored commits as both `Riley Oest` and `roest1` — a local `user.name`
  and GitHub's web UI disagreeing — while the email was identical on every
  one. Matching the name filed your own branches under someone else.

### The three-dots

`enter` on a row opens a `Menu`: that row's actions, named, with the exact
command shown in the pane. It needs nothing new from `reticle` — a menu is a
list of rows and `Flow::Push` opens it.

What a menu avoids is the only expensive part of the drawing: putting the
cursor ON a button inside a row needs column-wise focus, a second navigation
axis, and it would collide with `h`/`l` meaning close/open everywhere else. The
menu gets identical functionality on one axis. Direct keys stay available as
accelerators for the two or three actions done constantly, named in the footer.

**The surprise: most items are `Flow::Detach`, and that largely dissolves the
text-input blocker.** `gh pr create` prompts for a title and body on a tty;
`gh pr edit` prompts for what to change; `git push --delete` prints what it did
and fails loudly on a protected branch. Handing them the real terminal buys
text entry, confirmation and error reporting in the tools' own words. So "full
functionality, all in a TUI" does NOT wait on a text-input widget — it waits on
FILTERING, which is a different and smaller thing.

Showing the command is the confirmation. A destructive item is marked in the
row, in the pane and in the footer, and does not add a prompt of its own: the
tool being run already asks or already reports, and two confirms is one too
many.

### The repo level earned its strip

With Branches and Actions there are two repo screens, so the repo level is a
`Host` now — `[Branches] [Actions]` — which is the design's centrepiece. Four
of the six tabs are still unported. A one-tab strip is a title that cost a row,
which is why this waited for the second screen.

### One unmet detail, deliberately

The design asks for a lock glyph on protected branches, next to the name.
`U+1F512` is East Asian Wide: two cells in wezterm, one in terminals that
disagree, in the one column whose whole job is being fixed-width. That is the
bug `Verdict::badge` already refuses, so protection became a `prot` text column
on the right. `★` (default) and `●` (checked out) stay — both single-width and
both already used here. If a lock is wanted back it is one line, and the
footer legend carries the meaning either way.

## Directional navigation, and the emoji coming back (2026-10-22)

Both from using it. Both were my calls to get wrong and Riley's to catch.

**`Tab` was a mode.** It was the only way to reach the strip, and a key whose
whole job is changing what the other keys mean is exactly what the nav contract
exists to avoid. Riley's word for the fix was a smart TV, which is the right
model: hjkl moves around the screen and the EDGE of a region is the door to the
next one. `k` on the first row reaches the strip, `h`/`l` there change tab, `j`
drops back in; `l` on a row with nothing to expand goes right into the pane,
`j`/`k` scroll it, `h` returns.

The rule that keeps the screens out of it: a direction acts within the focused
region, and when it cannot, focus moves instead. For `h`/`l` that is read off
`Flow::Continue`, which already meant "nothing happened" — so no screen had to
change to take part. `Tab` still works; it is no longer the only way.

It forced one correction that was wrong before and invisible: **`Action::Open`
was being treated as a synonym for `Activate`**, so `l` on a run drilled into
its jobs and the pane beside it could not be reached at all. `l` now only
expands or moves right.

And one judgement call: focus enters the pane whenever one EXISTS, not only
when it has more lines than fit. Gating on scrollability reads as a dead key —
on a run whose body happens to fit, `l` silently did nothing, which is the "why
won't it move" the whole model is meant to remove.

**The emoji ban was a bug fix pointed the wrong way.** Glyphs were dropped from
badges and markers because `✅` is one `char` and two cells, so columns of them
drifted. That is arithmetic. The glyphs carry colour and meaning a word does
not — which is why the fzf implementation used them — so the right answer was
to measure properly, which is `reticle::width`.

Back now: `✅ ok` / `❌ fail` status badges, a 🔒 on a protected branch next to
its name (the design doc detail an earlier version could not meet), ⭐/🌱/🌿 on
the branch groups, and a glyph on every tab — the strip being where they earn
the most, since it is what you look at to navigate. The WORD stays beside the
status glyph, because a white circle does not read as "neither passed nor
failed".

Not emoji'd: org rows, member rows, repo rows, menu items. There, they would be
noise rather than signal.

Measured rather than assumed along the way: **`⏭` is NARROW** where every other
status glyph is wide, which is why the bash version wrote it as `"⏭ "` with a
trailing space; the skip badge uses `⏩` instead. And the character-versus-cell
confusion bit **three times in one session** — twice in a test asserting
alignment and once in the pty harness used to verify it — always the same way:
`str::find` returns bytes, `chars().count()` returns characters, and neither is
what the terminal does.

## Secrets and Environments (done 2026-10-23)

The last two screens, done together because they are one subject: an
environment secret IS a secret, and the environment list is what tells the
Secrets screen what its groups are. One `Req::Json` serves both tabs, so
whichever you open first pays for it.

### Secrets: groups, not a dialog

The fzf screen listed repository and environment secrets in one flat list with
a glyph to tell them apart, which was right — the question you arrive with is
"is `DEPLOY_TOKEN` set anywhere" rather than "list the staging ones". Groups
keep that and gain two things the flat list could not have: `/` narrows across
every scope at once, and **the scope of a new secret is whichever group the
cursor is in**, so the "Where does it live?" menu the bash version opened first
is gone. Navigate, do not ask.

The value needs no widget and must not have one. `gh secret set NAME` reads it
from the terminal with echo off and encrypts it locally before it leaves the
machine, so `Flow::Detach` means the value is never in a `String` in this
process and cannot end up in a redraw. A field here would be strictly worse at
the only part that matters.

The NAME is asked for, because gh takes it as an argument — and it is passed
**as typed**, where bash upper-cased it. GitHub treats secret names
case-insensitively, so that was a convention rather than a requirement, and
silently rewriting what someone typed is not a thing to do on their behalf.
What IS checked is the part GitHub will refuse (the character set, the reserved
`GITHUB_` prefix), because learning that from a round trip means typing a name,
handing over the terminal, typing a value, and only then being told.

### Environments: the whole environment, every time

`PUT /repos/{owner}/{repo}/environments/{name}` is "create or update an
environment", and **the documentation does not say what happens to a parameter
you leave out.** That was checked rather than assumed, and it decided the
design: the bash version sent `{wait_timer: n}` alone, so if omission clears,
setting a wait timer silently dropped the required reviewers — and nobody would
find out until a deploy that should have waited for an approval did not.

So every change here composes the complete desired state. Whatever the
semantics, the environment afterwards is what the pane showed plus the one
change, and `Menu`'s confirm prints the exact command so it can be read first.

That cost nothing, because `gh api`'s field syntax carries all of it with no
shell and no temp file — verified against `gh api --verbose` on a path that
could not create anything, before any of the screen was written:

```
-F 'reviewers[][type]=User' -F 'reviewers[][id]=123'   an array of objects,
                                                       one per pair, in order
-F 'reviewers[]'                                       an empty array
-F 'deployment_branch_policy[protected_branches]=true' a nested object
-F deployment_branch_policy=null                       a real JSON null
```

The list endpoint already returns the protection rules and the branch policy,
so the screen is one call where bash fetched each environment again for its
preview. Only the pane's two extras — the environment's own secrets and its
last five deployments — need a request, and those are prefetched one row ahead,
the same rule the run list uses.

### The reviewer picker, and why it had to be a picker

Required reviewers are the one thing here that could not be a field: the API
takes a numeric user id, and no amount of typing produces one. The
collaborators endpoint hands back logins WITH their ids, so a list to tick is
both nicer than typing and the only shape that works at all.

It also matches the semantics. The field is a SET the PUT replaces wholesale,
so the picker opens **pre-ticked with whoever is required now** — editing a set
as a set is the only way to add a reviewer without dropping the others. And
whoever is required is a candidate whether or not they are a collaborator: a
team never will be, and an outside reviewer would otherwise vanish from the
list that replaces them.

This is the shape the multi-select dropdown in `GITHUB_TUI.md` asks for, built
where a round trip forced the issue. PR labels and reviewers still take a typed
name, because `gh pr edit --add-label` accepts one — so that remains a want
rather than a blocker.

### Three bugs, all from driving it rather than writing it

The same pattern as every previous screen, and the tests that passed first did
not catch any of them.

1. **`Host` never forwarded `answered()`.** A hosted screen returning
   `Flow::Ask` got its field, the field took the text, and the answer went to
   the trait default and vanished — a question that silently did nothing. This
   is the THIRD forward forgotten the same way (`split`, `sidebar`, now this),
   and it took a while to see because `Menu` had been the only thing that
   asked, and a `Menu` is pushed rather than hosted. So `Flow::Ask` worked
   everywhere it had been used, right up to the first hosted screen that asked
   for itself. The rule now lives on the trait: **a method with a default body
   is a method `Host` has to forward.**
2. **A placeholder row is a row.** With no environments the screen draws "no
   environments yet", so the rows below it sit where a single environment would
   have put them — and reading the position off `envs.len()` alone put
   `+ new environment` one row too high, on exactly the repo where creating one
   is the only thing the screen can do. `enter` on it did nothing. The
   position-walk test now covers the empty shape too.
3. **A long command was truncated in the confirm.** `argv.join(" ")` was fine
   while every item was `gh pr merge 86 --repo x`; an environment PUT comes to
   three hundred characters. Showing the command IS the confirmation here, so a
   confirm you cannot read all of is not one. `menu::wrap_argv` breaks it at
   argument boundaries and keeps a flag with its value.

A fourth, smaller: the pane sat on `asking github…` forever for a repo you can
only read, because "not yet" and "cannot" were the same `None`. Listing an
environment's secrets needs admin, and an honest-looking "none" there would be
the same lie `Got::Denied` exists to stop telling. The picker has the mirror
case — it says the collaborator list failed **even though it has rows**,
because the rows are then only the already-required ones, and a short list that
looks like the whole list is the one way that screen could mislead.

### Where parity stands

**42 ported, 2 partial, 1 todo, 4 dropped.** What is left is one row and one
decision: `screen-actions-for` needs the Actions screen constructible from a
slug and a sha rather than from an `index::Repo`, and the two `partial` rows
are both only the EFFECTIVE branch rules — the same ruleset API as the dropped
`rulesets` row, so the honest question is whether they become a third argued
`dropped` rather than work.

## A commit's runs, and a toggle that comes back (done 2026-10-23)

`screen-actions-for` was the last parity row that was work rather than a
decision, and it is small: bash's `ctrl-a` on the PR screen wrote the head sha
to a file and re-entered the same Actions screen, which read the file as its
scope. Here it is a row in the pull request menu — **Workflow runs for this
commit** — and a second constructor.

**It takes a slug and a sha, not an `index::Repo`, and that is the whole reason
a second constructor exists.** `Actions::open` runs `git rev-parse HEAD` and
reads the clone's checked-out branch, neither of which is available here: a
pull request's head commit need not be on this disk at all. It is a fork, or a
branch this clone has never fetched. So `for_commit` reads nothing local and is
handed the pull request screen's own fetcher, which is the same repo — a run
list is never cached, but a completed run's jobs and logs are, so drilling in
from here reuses whatever the Actions tab already fetched.

**The part that was not obvious: `b` had to offer a different pair.** The
existing arm widened a commit scope to every branch, and that is a door that
does not come back — nothing on screen afterwards names the commit, so the only
route back to it is `q` out and open the menu again. A toggle that cannot
return is not a toggle. So the screen remembers the commit it was *opened* for,
separately from the scope `b` has got to since, and the pair it offers is that
commit and the branch carrying it. `scope` is where you are; `commit` is what
the screen is about, and the second is what makes the first reversible.

Two smaller consequences, both of which read as polish and are really the same
point — a mark that is always on is not a mark:

- **The HEAD dot switches off inside a commit scope**, where every run is that
  commit and a dot on every row says nothing. Widen to the branch and it
  returns, now answering the question you actually have: which of this branch's
  runs belong to the commit I came from.
- **The runs are keyed on the head COMMIT, never the head branch.** `gh pr
  list --json headRefOid` carries it, and a branch name would answer for
  whatever is on the branch now rather than for what was reviewed — which on a
  pull request that has been pushed to since is a different answer that looks
  like the right one.

The row is offered whatever state the pull request is in, including merged: a
merged pull request's runs are exactly what you go looking for afterwards. It
is offered only when `headRefOid` came back, so nothing builds a query for a
commit it does not know.

### Two things only driving it found

Both were invisible to the tests, which is the pattern every screen here has
repeated.

**The list was five identical rows.** Every run of one commit carries the same
`display_title` — the pull request's — so pointing it at `cli/cli` drew *Allow
installation tokens to attac…* five times, truncated, with nothing to tell them
apart. The workflow name is what identifies a row inside a commit, and it had
to go in the LABEL rather than the detail: the list column is 52 cells and the
detail is the first thing to go. With the run NUMBER too, because a workflow
can run more than once on a commit — the next pull request tried had three
`pull_request_target` runs of the same workflow, where the number is all there
is. It is spelt the way the pane's header already spelt it: `PR Triaging #3365`.

**`b` back to the commit showed an empty list.** `tick` syncs when the
fetcher's epoch moves, which is right for something arriving and wrong for a
toggle — switching back to a scope answered a moment ago makes nothing arrive,
so the screen reported "no workflow runs here yet" about a scope holding six
runs. `toggle_scope` calls `sync()` itself now.

That one is older than this change and reachable from the Actions tab by
pressing `b` twice; what hid it is a clock. A live run re-arms the list timer
and that refresh does bump the epoch, so on any repo with something building
the list came back a second later. It only showed where everything had
finished — which is every commit scope on a pull request that has stopped
moving, so the new screen is where it was always going to surface.

Testing it needed a seam: `Fetcher::seed`, `#[cfg(test)]` only, because
`request` reaches the network and `get` is the only way back out, so a screen's
behaviour on an answer it ALREADY HAS could not be set up. It does not bump the
epoch, which is the point rather than a shortcut.

Building the screen inside the menu item fires its run list when the menu
opens rather than when the row is chosen. That is the same prefetch the
environment menu's reviewer picker does, it is deduplicated by the fetcher, and
it is why the list is already drawn when the screen appears.

**Where parity stands: 43 ported, 2 partial, 0 todo, 4 dropped.** Everything
outstanding is one decision — whether the two `partial` rows become a third
argued `dropped`, for the same reason `rulesets` is one.

## The effective rules, and the argument I got wrong (done 2026-10-23)

The last two parity rows, `pv-branch` and `branch-menu`, were both the same
missing thing: the EFFECTIVE branch rules. I argued for a while that they
should become a third `dropped`, on the grounds that they use the same ruleset
API as the dropped `rulesets` row. Reading `_ghbranch_effective` is what
settled it the other way, and the distinction is worth writing down because it
is the one the first argument missed.

`rulesets` is a browser and an **editor** — `_ghbranch_ruleset_menu` and
`_ghbranch_ruleset_apply` write. The argument for dropping it is that nobody
has exercised those writes, so porting would preserve their bugs and let an
unvalidated feature set a screen's shape. `_ghbranch_effective` is two GETs
rendered as lines. There is no write to get wrong and no shape to set, so
neither half of the argument reaches it. Porting cost less than arguing it
away, and it closed the gate by measurement rather than by decision — which is
what the table was built to prefer.

### The bypass is the point

`protected: true`, which the branch table already showed, answers a weaker
question than it looks like it does. A ruleset with a bypass actor turns every
rule under it into guidance that somebody — possibly you — can push straight
past. So the bypass goes in the group's DETAIL, where it reads without
selecting anything, and the actors go in the pane:

```
  🛡 main-branch-rules        1 can bypass     4
      deletion
      non fast forward
      pull request              1 approval · code owners
      required status checks    11 checks · strict
```

with the pane saying `RepositoryRole 5  through a pull request` and why that
matters. An unreadable ruleset says **"who can bypass it is unknown"** rather
than nothing, for the same reason the reviewer picker says its collaborators
call failed: the rules above it still apply and still list, so a missing
bypass line must not read as "none".

### "No rules" is not "unprotected by mistake"

An empty answer is the normal, correct state for a feature branch — a ruleset
is written against a ref pattern and a feature branch is outside every one of
them. The bash version said so in as many words and the sentence is ported,
because a blank screen here reads as a finding.

### The parameters render generically

Two rule types get a hand-written summary, the two worth reading at a glance.
Everything else is derived from whatever JSON came back, which is not
future-proofing for its own sake: `copilot_code_review` already exists, did not
when the bash version was written, and showed up with its settings needing no
code. The summary lists only what is switched ON; the pane shows the OFF ones
too, because "not strict" is a fact you opened the rule to learn, and expands
the required-checks array by name — "which checks" is most of why anyone opens
that rule.

### Measured: a slash in a branch name needs no encoding

`GET /repos/{owner}/{repo}/rules/branches/{branch}` takes the branch as the
REST of the path. Asked for `rules/branches/main/x` on a repo whose `main` has
four rules, it answers `[]` rather than 404 — so the route is greedy and
`feat/github-tui` passes through unencoded, as the bash version assumed without
checking. Everything outside the unreserved set is still escaped, because `#`
is legal in a branch name and would otherwise start a fragment.

### The local copy, in a cell that already existed

`pv-branch`'s other half was whether you have the branch locally. The table
lists REMOTE branches, so it could not say — and that is the question in front
of "should I check it out". It needed one more `for-each-ref`, over
`refs/heads`, and no new column: the marker cell now has three states, `●` for
checked out, `○` for fetched, blank for remote only. Blank is the common case
on a long list, which is the right way round. The menu's Checkout says which of
the two acts it is about to perform, since creating a branch and moving to one
are different things.

What is NOT ported, and the parity row says so rather than quietly claiming it:
`pv_branch`'s twenty-line commit log. It needs a pane, and the Branches screen
is `Split::Full` by an argument that still holds.

### One bug, found by driving into it by accident

`New pull request` ran `gh pr create --head <branch>` with no `--repo`, so it
resolved the repo from the process's working directory. It worked when `github`
was launched from inside the clone and failed with `not a git repository`
everywhere else — and launching from anywhere is the entire point of the repo
index. Every other item in that menu passed `--repo`; this one place did not.

The test that now covers it is structural rather than about this item: every
`gh` command a branch menu offers must name the repo somewhere, and every `git`
command must carry `-C`. It fails on the old argv, which is the only version
of this test worth having.

## Still open

- ~~Filtering.~~ ~~Text input.~~ **Both done (2026-10-23).** `/` narrows any
  list and is framework-owned, so every screen already written gained it
  untouched. Matching is case-insensitive substring and ORDER-PRESERVING: fzf
  also reordered by score, and that half is not portable here, because a run
  list is newest-first and branches are grouped — a score order would answer
  "which matched best" over "what is going on here".

  `Flow::Ask` + `Screen::answered` is the text half, and it came out far
  smaller than planned. **`gh pr create` and `gh pr edit` prompt for titles and
  bodies themselves**, on the real terminal via `Flow::Detach`, so `Ask` only
  ever handles short IDENTIFIERS — a branch name, a secret's name. The widget
  was never what blocked Pull Requests; filtering was.

  Three bugs found by using it rather than by writing it: a collapsed group
  dropped by the filter emptied the screen with nothing to say why; the
  post-filter cursor landed on the heading above the match, so the next `enter`
  collapsed it; and an early `continue` after a field silently swallowed a
  `Flow::Push` from `answered`. Reasoning in `tui/CLAUDE.md`.

  The confirm half then moved into `Menu`, which makes it the shared answer
  after all. The reason was a hole Riley spotted in the rename and which turned
  out to be wider: nothing in a menu asked anything, so **deleting a remote
  branch was one `enter` from a menu row.** The note defending that conflated
  two different things — `git push --delete` REPORTS afterwards and `gh api -X
  POST` does neither. Reporting is not confirming.

  `Item::confirm()` asks, `danger()` implies it, and where the tool genuinely
  does stop and wait the flags stay off, so there is only ever one prompt. The
  confirm comes after the field, so what is approved is the filled command.
- **The multi-select dropdown**, which is the clearest spec in
  `GITHUB_TUI.md`: enter opens, me preselected at the top, enter toggles, left
  returns to the title row, enter collapses with the selections intact. It is a
  WIDGET, shared by Issues' and PRs' `Created by` / `Assigned to` / `Labels`
  and "so on where prevalent" — so it belongs in `reticle` once, not per
  screen. It also overloads `h`/`l`/`enter`, which currently mean close/open
  and activate, so it needs a modal state in `nav` for the same reason
  filtering does. Doing both at once is probably one change.

  **Half of it exists twice already**, which narrows what is left. The PR
  sidebar's `Control::Many` is the dropdown-in-a-list version, and the
  environment reviewer picker is the ticked-set-as-a-screen version. The
  remaining question is whether those two collapse into one `reticle` widget or
  stay two shapes for two situations — a filter you open beside a list, and a
  set you edit on its own screen before sending it. The second one has to be
  a screen regardless, because it ends in a command that needs confirming.
- ~~Inline row buttons.~~ **Settled, and the first version of this entry was
  wrong.** It said the drawn `[PR]`/trash/three-dots were "mouse idioms" to be
  replaced by keys, which reads as a veto on the functions and is not what this
  repo believes: `tui/CLAUDE.md` says a key you have to be told about is a key
  nobody finds, so a visible labelled action beats a hidden binding. The bash
  implementation already worked the right way too — `enter` on a PR row opens
  thirteen actions, on a branch row seven. See **The three-dots** below.
- ~~**Text input, and a shared confirm.**~~ **Done, and this entry was
  written before the answer was known.** It said secret-set, env-create and
  pr-create all needed a `_gh_input` equivalent. Two of the three never did:
  `gh pr create` prompts for itself, and `gh secret set` reads the VALUE off
  the real tty with echo off, which is better than any field here could be.
  What was actually needed was a field for short identifiers — a name, an
  environment, a number of minutes — which is what `Flow::Ask` is.

  The confirm half landed in `Menu`, which is the shared answer this entry
  wanted. The Actions screen's own version stays where it is: `e` and `x` ask
  in the status line, `y` is the only key that acts, and any key or any cursor
  movement withdraws. It is screen-local and safe by construction, and it
  guards two keys rather than a list of items — a `Menu` for two keybindings
  would be a screen for a yes/no.
- ~~A scrolling pane.~~ Done, as a consequence of directional focus: `l` moves
  into the pane and `j`/`k` scroll it. The render-time tail budget stays, so
  the FIRST screenful is still the useful end of a failure — scrolling is for
  the rest, and `L` still pages the whole thing in `less`.
- **Mouse.** fzf can bind mouse events. It cuts against the keyboard
  contract, so it should be a deliberate decision rather than accretion.
- **Demos.** `vhs` is the modern single-binary option; worth a recording now
  that the screens have stopped moving.
