# `github`: parity before the swap

**The swap happened on 2026-10-24.** `bash/bash_github_tui` is deleted,
`github` is `tui/github`, and this file is now a RECORD rather than a gate.
What it still answers is the only question that outlives the port: what did
this deliberately not carry, and why. That is the four `dropped` rows, each
with its argument in its own row.

It existed because "don't lose any functionality" is a claim nobody can check
from memory — the fzf implementation was 2500 lines with 49 worker verbs, seven
screens and four menus, and most of it was behind a keystroke nobody had typed
in months.

## How it stayed honest, while it was a gate

The left column was **derived from the tree, not hand-kept**: every verb in
`_ghw_main`'s dispatcher had to appear here, asserted by a CI step, so adding
or renaming a verb in the bash file failed until this table said what happened
to it. The gate was the other half: CI refused `github` entering
`tui/deps.sh`'s `crates=(...)` while any row said `todo` or `partial`, so the
condition could not be met by deciding it had been.

Both are gone with the file they read — the derivation is impossible now, not
merely moot.

## What a derived table cannot see, which is worth knowing next time

It was derived from the **dispatcher**, and three things the swap needed were
not dispatcher verbs:

- `bashrc` sourced `~/.bash_github_tui`, and `deps.conf` linked it. Mechanical,
  and CI would have caught both.
- **`_gh_tab_var`** — the OSC 1337 `gh_tui` user var that `wezterm/shared.lua`
  reads to put GitHub's mark on the tab while a session is running. Nothing
  would have caught this. It is real, user-visible functionality that the gate
  was built to protect and could not see, and it was found by grepping for
  every mention of the file about to be deleted rather than by the table. It
  now lives in `TabMark` (`tui/github/src/lib.rs`), with the wire format
  pinned by a test.

A derivation covers exactly what it derives from. If the next table of this
shape is derived from one entry point, the grep is still part of the job.

Statuses:

- **ported** — the Rust screens do this. Not necessarily identically; where the
  shape changed deliberately, `github-tui.md` says why.
- **partial** — some of it. The missing part was named in the row, and a
  partial row blocked the swap exactly as a `todo` did. None are left.
- **todo** — not there yet. None are left.
- **dropped** — deliberately not carried over, with the reasoning in the row.
  This is the only status that is a decision rather than a measurement, so each
  one needs an argument, not a shrug — and it is the only one that still means
  anything now that the table is a record.

## What is NOT in scope

`gha` is a separate one-shot command in `bash/bash_github`, not part of the
TUI, and it stayed. So did everything else in `bash_github` and `bash_git` —
the swap deleted `bash_github_tui` and the `github()` function in it, nothing
else, which is what the file split was enforced for. `h github`'s `github`
half was rewritten in the same commit; its `gha` half is unchanged.

## The table

| verb | status | where it went, or what is missing |
|---|---|---|
| `branch-checkout` | ported | the branch menu's Checkout |
| `branch-delete` | ported | the branch menu's Delete remote branch |
| `branch-menu` | ported | all 7, plus Rename, which bash never had. Effective rules opens `rules.rs` rather than paging a dump, and it is offered on every branch — "no rules apply" is a different answer from "unprotected by mistake", and only the call tells them apart |
| `cancel` | ported | `x` |
| `env-create` | ported | the `+ new environment` row — `gh api -X PUT repos/{repo}/environments/{name}`, which is what the GitHub UI's New environment does: it arrives with no gates |
| `env-delete` | ported | the environment menu's Delete environment, which asks first |
| `env-menu` | ported | `envs::Envs::env_menu` — wait timer, self-review, required reviewers (a picker rather than a typed name, because the API takes an id), set a secret here, delete. The browser item became `o`, which is the key that leaves the terminal on every screen |
| `hub-prefetch` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `hub-refresh` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `list-branches` | ported | `branches.rs` — the full-width table |
| `list-envs` | ported | `envs.rs` — one call, because the list endpoint already carries the protection rules and the branch policy. bash fetched each environment again for its preview |
| `list-prs` | ported | `prs.rs` — `gh pr list --json` in one call, filters applied to the fifty that came back |
| `list-runs` | ported | `runs.rs` — the run list, 15s live refresh |
| `list-secrets` | ported | `secrets.rs` — the repository's and each environment's, as groups, so `/` narrows across every scope at once |
| `list-steps` | ported | `steps.rs` — jobs and steps as a tree |
| `log-job` | ported | `L` on a job row, into `less` |
| `log-run` | ported | `L` on the Actions screen |
| `log-step` | ported | `L` on a step row, into `less` |
| `open` | ported | `o` on every screen |
| `open-branch` | ported | the branch menu's Open in browser |
| `open-run` | ported | `o` on the steps screen |
| `open-settings` | ported | `o` on the Secrets and Environments screens, which goes to the page holding whatever the cursor is on |
| `pr-checkout` | ported | the PR menu's Checkout locally |
| `pr-create` | ported | the sidebar's `new pull request` — `gh pr create` prompts for title and body itself |
| `pr-menu` | ported | `prs::pr_menu` — 12 of the 13, offered only when they apply. Labels and Reviewers take a typed name rather than a picker |
| `prs-label` | ported | the `state` dropdown in the sidebar, which says what it is set to |
| `prs-next` | ported | the same dropdown — a list to pick from rather than a key that cycles |
| `pv-branch` | ported | the row carries protection, ahead/behind, author, subject, checks, PR, and now whether you have a local copy — `○` for fetched, `●` for checked out, blank for remote only, in the cell that already existed. The effective rules are a screen of their own, since the bypass actors need more room than a column. The 20-commit log is not here and is NOT claimed: it needs a pane, and this screen is `Split::Full` by argument |
| `pv-env` | ported | `envs::Envs::pane` — the gates, the branch policy, the environment's secrets and its last five deployments |
| `pv-hub` | dropped | the tab strip replaced the hub's NAVIGATION, and tabs replaced its summary too: the hub previewed each area because the bash screens were NESTED -- hub, enter Actions, esc, enter PRs -- so surveying the repo without entering anything was worth a screen. With a strip, each tab IS what the hub previewed, one `l` away, and `gha` already answers the HEAD-check-runs view from the shell without a TUI. Riley's call, having looked at it |
| `pv-job` | ported | `render::job_body` |
| `pv-pr` | ported | the row carries review, checks, author, age, branches and ±; the mock has no preview pane, so the detail is the menu |
| `pv-run` | ported | `render::run_header` + `run_body` |
| `pv-secret` | ported | `secrets::Secrets::pane` — the name, the scope, what it is called in a workflow, and why there is nothing else to show |
| `pv-step` | ported | `render::step_body` |
| `rerun` | ported | `e`, with the failed-jobs/all distinction |
| `rulesets` | dropped | the browser/EDITOR, unvalidated, which is a different thing from the read-only `rules.rs` that `branch-menu` now opens: that one is two GETs rendered as lines, where this one writes. Porting a write path nobody has exercised would preserve its bugs and let it set a screen's shape. Use it on github.com first. See github-tui.md |
| `runs-label` | ported | `runs::Scope::label` in the title bar |
| `runs-toggle` | ported | `b` on the Actions screen |
| `screen` | ported | the tab strip dispatches to a screen; `reticle::Host` |
| `screen-actions` | ported | the 🚀 Actions tab |
| `screen-actions-for` | ported | the PR menu's Workflow runs for this commit, which is bash's `ctrl-a` as a row. `runs::Actions::for_commit` takes a slug and a sha, because a pull request's head commit need not be on this disk at all; `b` there pairs the commit with the branch carrying it rather than widening to everything, so the screen can get back to the question it was opened for |
| `screen-branches` | ported | the 🌿 Branches tab |
| `screen-envs` | ported | the 🌍 Environments tab |
| `screen-prs` | ported | the 🔀 Pull Requests tab |
| `screen-secrets` | ported | the 🔑 Secrets tab |
| `screen-steps` | ported | pushed by enter on a run |
| `secret-delete` | ported | the secret menu's Delete, marked destructive, so it asks |
| `secret-set` | ported | two ways in, both ending in `gh secret set` on the real tty: the secret menu's Set a new value, and the `+ new secret` row in each group. The value is read with echo off by gh and never passes through this program |
## Where that leaves it

**45 ported, 0 partial, 0 todo, 4 dropped** (2026-10-23). Nothing is
outstanding, and the gate this table exists to hold is open.

Secrets and Environments landed together, since an environment secret is a
secret and the environment list is what tells the Secrets screen its groups.
`screen-actions-for` followed. The last two were `pv-branch` and
`branch-menu`, both of them the effective branch rules — argued for a while as
a third `dropped`, and that was wrong: the rules call is READ-ONLY, so the
reason `rulesets` is dropped (an unexercised write path setting a screen's
shape) does not reach it. Porting cost less than arguing it away, and it
closed the gate by measurement rather than by decision.

**The four `dropped` rows are the whole of what this port does not carry**,
each with its argument in its row: the hub's three verbs, which the tab strip
replaced, and the ruleset editor.

One gap that is not a parity gap, because bash typed them too: PR
**labels and reviewers take a typed name** rather than a picker. The
environment reviewer picker is the shape it wants, and now exists to copy —
the difference is that `gh pr edit --add-label` accepts a name, so there was
never a round trip forcing the issue.

## What this file is not

A list of features to tick off for its own sake. Two rows are already arguments
for deleting something rather than porting it, and more may follow — `rulesets`
is dropped because porting unvalidated behaviour preserves it bug-for-bug and
lets it set the shape of a screen. If a `todo` turns out to be something nobody
has ever used, the right move is to change it to `dropped` WITH the argument,
not to port it so the table goes green.
