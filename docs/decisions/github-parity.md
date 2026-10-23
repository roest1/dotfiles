# `github`: parity before the swap

The bash implementation gets deleted in ONE commit, and this file is the
precondition for writing it. It exists because "don't lose any functionality"
is a claim nobody can check from memory — the fzf implementation is 2500 lines
with 49 worker verbs, seven screens and four menus, and most of it is behind a
keystroke nobody has typed in months.

## How this stays honest

The left column is **derived from the tree, not hand-kept**: every verb in
`_ghw_main`'s dispatcher in `bash/bash_github_tui` must appear here. A CI step
asserts that, so adding a verb to the bash file — or renaming one — fails until
this table says what happened to it.

The gate is the other half: **CI refuses the swap while any row says `todo`.**
If `github` appears in `tui/deps.sh`'s `crates=(...)`, every row must be
`ported` or `dropped`. So the condition cannot be met by deciding it has been.

Statuses:

- **ported** — the Rust screens do this. Not necessarily identically; where the
  shape changed deliberately, `github-tui.md` says why.
- **partial** — some of it. The missing part is named in the row, and a partial
  row blocks the swap exactly as a `todo` does.
- **todo** — not there yet.
- **dropped** — deliberately not carried over, with the reasoning in the row.
  This is the only status that is a decision rather than a measurement, so each
  one needs an argument, not a shrug.

## What is NOT in scope

`gha` is a separate one-shot command in `bash/bash_github`, not part of the
TUI, and it stays. So does everything else in `bash_github` and `bash_git` —
the swap deletes `bash_github_tui` and the `github()` function in it, nothing
else. `h github` documents both and will need the `github` half rewritten.

## The table

| verb | status | where it went, or what is missing |
|---|---|---|
| `branch-checkout` | ported | the branch menu's Checkout |
| `branch-delete` | ported | the branch menu's Delete remote branch |
| `branch-menu` | partial | `menu.rs` has 6 of 7 — Set as default landed with text input, and Rename (which bash never had) with it. Only Effective rules is missing, and it is the same ruleset API as the dropped `rulesets` row |
| `cancel` | ported | `x` |
| `env-create` | todo |  |
| `env-delete` | todo |  |
| `env-menu` | todo | 5 items: wait timer, required reviewers, set a secret, delete, browser |
| `hub-prefetch` | todo | the hub's six panes were a repo DASHBOARD — ci, prs, branches, secrets, envs and a header, fetched in parallel. The tab strip replaces its navigation but not its at-a-glance summary |
| `hub-refresh` | todo | see hub-prefetch |
| `list-branches` | ported | `branches.rs` — the full-width table |
| `list-envs` | todo |  |
| `list-prs` | todo | needs filtering first |
| `list-runs` | ported | `runs.rs` — the run list, 15s live refresh |
| `list-secrets` | todo |  |
| `list-steps` | ported | `steps.rs` — jobs and steps as a tree |
| `log-job` | ported | `L` on a job row, into `less` |
| `log-run` | ported | `L` on the Actions screen |
| `log-step` | ported | `L` on a step row, into `less` |
| `open` | ported | `o` on every screen |
| `open-branch` | ported | the branch menu's Open in browser |
| `open-run` | ported | `o` on the steps screen |
| `open-settings` | todo | `ctrl-o` on the Secrets and Environments screens |
| `pr-checkout` | todo |  |
| `pr-create` | todo | `gh pr create` prompts, so this is a menu item not a widget |
| `pr-menu` | todo | 13 items: diff, files, comment, approve, request changes, labels, reviewers, edit, merge, ready/draft, close, browser |
| `prs-label` | todo | the open/closed/all scope label |
| `prs-next` | todo | `ctrl-f` cycling the scope |
| `pv-branch` | partial | the row carries protection, ahead/behind, author, subject, checks and PR — but NOT the effective branch rules, nor whether a local copy exists |
| `pv-env` | todo |  |
| `pv-hub` | todo | see hub-prefetch |
| `pv-job` | ported | `render::job_body` |
| `pv-pr` | todo |  |
| `pv-run` | ported | `render::run_header` + `run_body` |
| `pv-secret` | todo |  |
| `pv-step` | ported | `render::step_body` |
| `rerun` | ported | `e`, with the failed-jobs/all distinction |
| `rulesets` | dropped | unvalidated behaviour — porting it would preserve it bug-for-bug and let it set the shape of a screen. Use it on github.com first. See github-tui.md |
| `runs-label` | ported | `runs::Scope::label` in the title bar |
| `runs-toggle` | ported | `b` on the Actions screen |
| `screen` | ported | the tab strip dispatches to a screen; `reticle::Host` |
| `screen-actions` | ported | the 🚀 Actions tab |
| `screen-actions-for` | todo | `Scope::Commit` is built and query-correct; nothing reaches it until the PR screen's `ctrl-a` exists |
| `screen-branches` | ported | the 🌿 Branches tab |
| `screen-envs` | todo |  |
| `screen-prs` | todo |  |
| `screen-secrets` | todo |  |
| `screen-steps` | ported | pushed by enter on a run |
| `secret-delete` | todo |  |
| `secret-set` | todo | needs text input, or `gh secret set` on the real tty |
## Where that leaves it

**22 ported, 2 partial, 24 todo, 1 dropped.** Roughly half, and the half that
is left is not the easy half: Pull Requests and Secrets both need text input or
filtering, and the hub was a dashboard rather than a list.

The order that unblocks the most, which is also the order the remaining work
should be done in:

1. **Filtering and text input**, with the multi-select dropdown. `reticle::nav`
   maps every bare char to `Action::Key(c)`, so there is no text-entry mode to
   hang any of it on. PRs and Secrets are built around all three.
2. **Pull requests** — the biggest single screen, and the one that makes
   `screen-actions-for` reachable.
3. **Secrets and Environments** — small once text input exists.
4. **The hub's summary.** The tab strip replaced the hub's NAVIGATION and not
   its content: six panes fetched in parallel telling you the state of CI, PRs,
   branches, secrets and environments at once. That is a real capability and it
   has no home in the current design yet. It may want to be the repo level's
   own first tab rather than a thing the strip does.
5. **The two partials**, which are small and specific: a branch's effective
   rules and whether a local copy exists, plus the two branch-menu items.

## What this file is not

A list of features to tick off for its own sake. Two rows are already arguments
for deleting something rather than porting it, and more may follow — `rulesets`
is dropped because porting unvalidated behaviour preserves it bug-for-bug and
lets it set the shape of a screen. If a `todo` turns out to be something nobody
has ever used, the right move is to change it to `dropped` WITH the argument,
not to port it so the table goes green.
