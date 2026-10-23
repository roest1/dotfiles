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
| `hub-prefetch` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `hub-refresh` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `list-branches` | ported | `branches.rs` — the full-width table |
| `list-envs` | todo |  |
| `list-prs` | ported | `prs.rs` — `gh pr list --json` in one call, filters applied to the fifty that came back |
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
| `pr-checkout` | ported | the PR menu's Checkout locally |
| `pr-create` | ported | the sidebar's `new pull request` — `gh pr create` prompts for title and body itself |
| `pr-menu` | ported | `prs::pr_menu` — 12 of the 13, offered only when they apply. Labels and Reviewers take a typed name rather than a picker |
| `prs-label` | ported | the `state` dropdown in the sidebar, which says what it is set to |
| `prs-next` | ported | the same dropdown — a list to pick from rather than a key that cycles |
| `pv-branch` | partial | the row carries protection, ahead/behind, author, subject, checks and PR — but NOT the effective branch rules, nor whether a local copy exists |
| `pv-env` | todo |  |
| `pv-hub` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `pv-job` | ported | `render::job_body` |
| `pv-pr` | ported | the row carries review, checks, author, age, branches and ±; the mock has no preview pane, so the detail is the menu |
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
| `screen-prs` | ported | the 🔀 Pull Requests tab |
| `screen-secrets` | todo |  |
| `screen-steps` | ported | pushed by enter on a run |
| `secret-delete` | todo |  |
| `secret-set` | todo | needs text input, or `gh secret set` on the real tty |
## Where that leaves it

**30 ported, 2 partial, 16 todo, 4 dropped** (2026-10-23). Filtering, text
input and Pull Requests all landed, and the hub was dropped with an argument
rather than ported.

What is left, in the order that unblocks the most:

1. **Secrets** (5 rows) — list plus set and delete. Small: `gh secret list
   --json` through `Req::Cmd`, and the two actions are menu items.
2. **Environments** (7 rows, including `open-settings`) — a list and a
   five-item menu, mostly `gh api`.
3. **`screen-actions-for`** — the PR menu offering "the runs for this commit".
   `runs::Scope::Commit` is built and query-correct; what it needs is a way to
   construct the Actions screen from a slug and a sha rather than from an
   `index::Repo`.
4. **The two partials** — both are only the effective branch rules, which is
   the same ruleset API as the dropped `rulesets` row. Worth deciding whether
   that makes them a third `dropped` rather than work.
5. **The multi-select picker for PR labels and reviewers.** Those two menu
   items take a typed name today, which is honest but worse than a list. Not a
   parity gap -- bash typed them too -- but it is the one place the design doc
   asks for a dropdown and gets a field.

## What this file is not

A list of features to tick off for its own sake. Two rows are already arguments
for deleting something rather than porting it, and more may follow — `rulesets`
is dropped because porting unvalidated behaviour preserves it bug-for-bug and
lets it set the shape of a screen. If a `todo` turns out to be something nobody
has ever used, the right move is to change it to `dropped` WITH the argument,
not to port it so the table goes green.
