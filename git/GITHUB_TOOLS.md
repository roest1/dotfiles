# GitHub Terminal Tools

Interactive GitHub management from the terminal — no browser needed for most workflows.

> **One command: `gh-tui`.** (`gh-ui` is an alias for it.)

| Command     | What it does                                      |
| ----------- | ------------------------------------------------- |
| `gh-tui`    | **The hub** → every screen below, with preview    |
| `gha`       | HEAD's checks as a table, names linked to their jobs |

The screens — PRs, CI/Actions, Secrets, Branches, Environments — are reached
through the hub rather than as separate commands. Press `?` in any of them for
that screen's help.

## Navigation

Consistent across every screen — learn once, use everywhere:

```
Menus:   ↑↓ navigate    enter select    -/q back     (nvim-like)
Lists:   type to filter  enter select    esc back
Pagers:  r refresh       -/q back
```

## Dependencies

```sh
brew install gh fzf jq
gh auth login
```

---

## gh-tui — the hub

One command, live preview, access to everything.


The hub pre-fetches data in parallel (open PRs, CI status, secrets, environments, branches) and shows it in a live preview pane as you navigate. Select an item to jump into the full tool — when you're done, you return to the hub.

```
┌─────────────────────────────┬──────────────────────────────┐
│ 🔀 Pull Requests          > │ #42 Fix auth flow     ⏳     │
│ 📋 Pull Requests (mine)     │ #41 Add dark mode     ✅     │
│ ➕ Create Pull Request       │ #39 Refactor API      🔄     │
│ ───────────────────────────  │                              │
│ 🚀 CI / Actions              │                              │
│ ───────────────────────────  │                              │
│ 🔑 Secrets                   │                              │
│ 🌍 Environments              │                              │
│ 🌿 Branches                  │                              │
└─────────────────────────────┴──────────────────────────────┘
```

Each screen is reached through the hub. Press `?` inside one for its own help.

---

## CI / Actions — workflow viewer + logs

Choose scope first: **current commit (HEAD)** or **recent workflow runs** (cross-branch). Then pick a workflow → action menu → smart logs or step browser.


### Smart log view

Passing steps collapse to one line. Failed steps auto-expand with full output:

```
 ━━━ Build ━━━  4 passed  1 failed  0 skipped

 ✅  Set up job ·····································  2s
 ✅  Checkout ·······································  1s
 ✅  Install dependencies ···························  23s
 ❌  Run tests ······································  45s
 │
 │  FAIL src/utils.test.js
 │    ● should handle negative numbers
 │      Expected: -1
 │      Received: 1
 │
 ✅  Post checkout ··································  0s
```

Press `r` after pushing a fix to re-fetch — watch the failure turn green without leaving the terminal.

### Step browser

fzf list of all steps. Preview pane shows logs as you arrow through — no need to open anything. `enter` for full log in a pager.


---

## Pull Requests — Pull Request Management

Full PR lifecycle without leaving the terminal.


### Getting here

```sh
gh-tui        # then: 🔀 Pull Requests · 📋 Pull Requests (mine) · ➕ Create
```

The hub's three PR entries map to the filter picker, your own PRs, and the
creation flow respectively. Creating walks you through draft/ready and hands
off to gh's interactive flow.

The filter picker lets you choose what to view:

| Filter               | What it shows                        |
| -------------------- | ------------------------------------ |
| All open PRs         | Every open PR in the repo            |
| Needs my review      | PRs where your review is requested   |
| My PRs               | PRs you authored                     |
| Recently closed      | Last 50 closed PRs                   |
| Recently merged      | Last 50 merged PRs                   |

Select a PR to get the action menu:

| Action               | What it does                              |
| -------------------- | ----------------------------------------- |
| 👁 View details      | Full PR info in terminal                  |
| 📥 Checkout locally  | Switch to the PR's branch                 |
| 📝 View diff         | Colored diff in pager                     |
| 📊 View file changes | Browse individual files with diff preview |
| 💬 Add comment       | Inline or open your editor                |
| ✅ Approve           | With optional message                     |
| 🔄 Request changes   | Opens editor for feedback                 |
| 🏷 Manage labels     | Multi-select (TAB toggle) add/remove      |
| 👤 Request reviewers | Multi-select from collaborators            |
| ✏️ Edit title/body   | Rename or rewrite description             |
| 🔀 Merge             | Strategy picker (squash/merge/rebase)     |
| ❌ Close PR          | Close without merging                     |
| 🌐 Open in browser   | Fallback to GitHub UI                     |
| 🔍 View CI checks    | Pick a check → drill into logs/rerun      |

Most actions loop back to the menu — do multiple things on the same PR without re-running the command.

### Merge flow

Picks strategy → asks about branch deletion → merges. Checks for conflicts first.


---

## Secrets — Secrets Management


Manage repo-level and environment-scoped secrets. Values are **write-only** by design — GitHub never reveals them, not even through the API.

| Action        | Scope                                |
| ------------- | ------------------------------------ |
| List secrets  | Names + last updated (values hidden) |
| Set secret    | Secure input, auto-uppercased        |
| Delete secret | Pick from list, confirm              |

Works for both repo secrets and per-environment secrets (pick the environment first).

```
━━━ Repository Secrets ━━━

MY_API_KEY        Updated 2026-03-15
DATABASE_URL      Updated 2026-03-10

  ℹ  Values are hidden by design — only names and last updated shown
```

---

## Branches — Branches + Rulesets


**Rulesets, not classic branch protection.** This changed for a reason worth
knowing: the old version drove `/repos/{o}/{r}/branches/{b}/protection`, and on
a repo protected by a *ruleset* that endpoint returns `404 Branch not
protected`. So it reported `main` as protected in the branch list — that field
does account for rulesets — and unprotected on the very next screen. It would
also write a classic rule *alongside* a ruleset, leaving two overlapping
mechanisms and no clear answer to "which one blocked my push".

### Effective rules for a branch

Answers what actually governs a branch, across every ruleset that targets it:

```
━━━ Effective rules: main ━━━

  from ruleset 20169814  (roest1/dotfiles)
    • deletion
    • non_fast_forward
    • pull_request  approvals=1  codeowners=true
    • required_status_checks  strict=true  checks=10

  ruleset 20169814 bypass: RepositoryRole/5:pull_request
```

The bypass line is the point. "Protected" means little on its own — with a
bypass you can merge red and stale, so the rules are guidance you override
rather than a wall. Without one, and with required approvals on a solo repo,
nothing can ever merge. Either way you want it on screen.

### Managing a ruleset

Pick a ruleset, then toggle the things worth toggling:

| Action                        | Notes                                                  |
| ----------------------------- | ------------------------------------------------------ |
| View full ruleset             | Rules, conditions and bypass list as JSON               |
| Enforcement                   | `active` / `evaluate` / `disabled` — evaluate reports without blocking |
| Require branches up to date   | The `strict` flag. Turning it on means every merge invalidates every other open PR |
| Required checks               | Add/remove, picking from names CI actually reported     |
| Bypass mode                   | `pull_request` (no direct pushes) or `always`           |

### Required checks are picked, not typed

The add-a-check picker offers **only names the last CI run reported**, and the
screen flags both directions of drift:

```
  ✅ shellcheck
  ✅ manifest parses

  Reported by CI but NOT required:
    ○ bun audit (transitive advisories)

  ⚠️  Required but NOT reported by the last run — these block PRs
      indefinitely if the job was renamed or removed:
    ✗ old job name
```

That second list is the dangerous one. A required check that never reports
doesn't fail a PR — it blocks it forever, waiting on a status that will never
arrive. Typing check names by hand is how that happens.

### Other actions

| Action                     | What it does                                        |
| -------------------------- | --------------------------------------------------- |
| List branches              | 🛡 marks any branch covered by a rule                |
| Delete remote branch       | Safety check — won't delete the default branch       |
| Set default branch         | Change the repo's default                            |
| Legacy classic protection  | Read + delete only, for migrating a repo off it      |

Nothing in here *creates* a classic protection rule. Rulesets supersede them,
and a branch carrying both is a branch where "why was this rejected" has two
possible answers.

### Under the hood

Writes are read-modify-write through a single helper, because `PUT` replaces the
fields it receives — every edit passes a `jq` filter over the current ruleset
rather than assembling a payload, so no edit can silently drop a field.

And rulesets update with **`PUT`, not `PATCH`**. `PATCH` returns a bare `404`
that reads exactly like a permissions failure and isn't.

---

## Environments — Environment Management


Manage deployment environments (staging, production, etc.) with their own secrets, wait timers, and required reviewers.

### Environment details view

```
━━━ Environment: production ━━━

Protection rules:
  ⏱  Wait timer: 30 minutes
  👤 Required reviewers: roest1

Secrets:
  DEPLOY_KEY        Updated 2026-03-12
  AWS_SECRET        Updated 2026-03-10
```

### Actions

| Action                 | What it does                        |
| ---------------------- | ----------------------------------- |
| List environments      | Names + creation dates              |
| View details           | Protection rules + secrets together |
| Create environment     | Just name it                        |
| Set wait timer         | Minutes before deployment proceeds  |
| Set required reviewers | Pick from collaborators             |
| Delete environment     | Removes env AND all its secrets     |

---
