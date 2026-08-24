# GitHub Terminal Tools

The current repo on GitHub, from the terminal — one TUI for the things you'd
otherwise open a browser tab for.

> **One command: `github`.**

| Command  | What it does                                                          |
| -------- | --------------------------------------------------------------------- |
| `github` | **The hub** → Actions · Pull Requests · Branches · Secrets · Environments |
| `gha`    | HEAD's checks as a table, names linked to their jobs — the one-shot     |

Press `ctrl-/` in any list, or `?` in any menu, for that screen's help.

## The shape of it

Every screen is one fzf window: a list on the left, a **live preview** on the
right, and single-key actions on the list (the footer names them). Screens open
instantly and fill in — nothing waits on the network before it appears. What
the preview shows is the state of the thing *now*: a running workflow or a PR
with pending checks refreshes under the cursor by itself.

Screens open inside the screen below them, so **back is back**: `esc` returns
to the row you left, filter and scroll intact.

```
Lists:    type to filter   enter select   esc back   ctrl-r refresh
          ctrl-o open in browser   ctrl-/ help   (the footer has the rest)
Menus:    ↑↓ / jk   enter select   -/q back   ? help
Preview:  shift-↑↓ · alt-j/k · alt-u/d scroll   alt-p hide / show
```

## Dependencies

```sh
gh auth login          # gh, jq, and fzf ≥ 0.65 come from `make install bash`
```

fzf's floor is real: the live previews use `--listen`, and the chrome uses
`--style` and `--footer`, none of which the older fzf in apt has. `deps.conf`
installs fzf through mise for that reason; `github` says so if it finds an old
one instead of half-working.

---

## The hub

```
╭──────────────────────────────── 🐙 roest1/dotfiles ─────────────────────────────╮
│ ╭─────── 🌍 public · main · 0 open PR(s) ───────╮╭────────── 🚀 Actions ──────────╮ │
│ │ ▶ 🚀 Actions         runs · jobs · logs, live ││ HEAD 1ce6692 on main           │ │
│ │   🔀 Pull Requests   review · merge · create  ││                                │ │
│ │   🌿 Branches        rules · default · delete ││ ✅ 12 passed                   │ │
│ │   🔑 Secrets         repository · environment ││                                │ │
│ │   🌍 Environments    reviewers · timers       ││ ✅ shellcheck  17s             │ │
│ ╰───────────────────────────────────────────────╯│ ✅ manifest parses  18s        │ │
╰──────────────────────────────────────────────────╰────────────────────────────────╯─╯
```

The panes and the label fill in behind the menu as they load; `r` refetches
them. `enter` opens the screen; when you come back you're on the same row.

---

## 🚀 Actions

The last 40 runs, newest first, across every branch (`ctrl-b` narrows to the
branch you're on). `●` marks HEAD's commit. Type to filter — a branch, "fail",
a title.

**Hover a run and its jobs appear.** Passing jobs are one line. A job that
failed or is still running opens up to its steps, and a failed step shows the
tail of its own log right there — no menu, no second screen:

```
❌ failure · 37s · started 05:03 UTC

✅ bun audit (transitive advisories) ··············     6s
✅ link only (linux) ······························     3s
❌ install (macos / brew) ·························     7s
   ✅ Set up job ··································     1s
   ✅ Run actions/checkout@v7 ·····················     1s
   ❌ Install the bash section ····················     1s
     ┃ ▸ Run make install bash
     ┃ make install bash
     ┃ Unknown section: bash
     ┃ make: *** [install] Error 1
     ┃ ✖ Process completed with exit code 2.
   ⏭  Verify the bash section ·····················     0s
✅ install (ubuntu / apt) ·························    32s

✅ 9 passed   ❌ 2 failed
```

A run in progress refreshes every few seconds while you look at it — `▶` is
the step running now, `○` the ones still to come — and when it completes, the
list line flips from ⏳ to ✅/❌ on its own.

| Key      | Does                                                                 |
| -------- | -------------------------------------------------------------------- |
| `enter`  | jobs & steps: every step of every job, its full log on the right, `enter` pages it |
| `ctrl-o` | open the run on GitHub                                               |
| `ctrl-e` | rerun — the failed jobs if any failed, else the whole run (asks first) |
| `ctrl-x` | cancel a run in progress (asks first)                                |
| `ctrl-l` | the whole run's log, every job, in a pager                           |
| `ctrl-b` | this branch only / all branches                                      |

Where the logs come from: GitHub serves one log per *job*, not per step (the
run zip stopped carrying per-step files, which is why `gh run view --log` now
says `UNKNOWN STEP`). A step's lines are reconstructed — its timestamp window,
anchored on its own `##[group]Run …` marker and cut at its closing
`##[error]`. Exact for `run:` and `uses:` steps; the runner's own Set up /
Post / Complete steps get their whole window. Logs of completed jobs and
rendered bodies of completed runs are cached under `~/.cache/github/`, so a
second look is instant even in a new shell.

---

## 🔀 Pull Requests

```
review · ci · #      author   age   title                          branch      ±
🟣 ✓ #36   roest1  46m  let tests return early before expected …  fix-test  +2/-1
```

`ctrl-f` cycles the view — the list's label says which: **open → mine → needs
my review → recently merged → recently closed**.

The preview answers "can I merge this" first: state, author, `head → base`,
size, labels, the review decision and each reviewer's verdict, whether it's
mergeable and why not, every check with its duration, then the description.
Pending checks refresh by themselves.

| Key      | Does                                                       |
| -------- | ---------------------------------------------------------- |
| `enter`  | the action menu (below)                                    |
| `ctrl-o` | open on GitHub                                             |
| `ctrl-d` | the diff, in a pager                                       |
| `ctrl-k` | check it out locally                                       |
| `ctrl-a` | its workflow runs — the Actions screen scoped to the PR's commit |
| `ctrl-n` | create a PR from the current branch (draft or ready)       |
| `ctrl-f` | cycle the filter                                           |

The action menu — `-`/`q` returns to the list, each action returns to the menu:

| Action                 | What it does                                          |
| ---------------------- | ----------------------------------------------------- |
| 📥 Checkout            | switch to the PR's branch                             |
| 📝 Diff                | coloured diff in a pager                              |
| 📊 Changed files       | one file per row, diff on the right, `enter` pages it |
| 💬 Comment             | in `$EDITOR`                                          |
| ✅ Approve             | with an optional message                              |
| 🔄 Request changes     | in `$EDITOR`                                          |
| 🏷 Labels              | add / remove, `tab` to multi-select                   |
| 👤 Reviewers           | multi-select from collaborators                       |
| ✏️ Edit title / body   | title inline, body in `$EDITOR`                        |
| 🔀 Merge               | squash / merge / rebase, then delete the branch or keep it |
| 🔁 Mark ready / draft  | flip draft state                                      |
| ❌ Close               | close without merging (asks first)                    |
| 🌐 Open in browser     |                                                       |

---

## 🌿 Branches

Every branch on the remote, default first, then by most recent commit:

```
● ⭐ main               46m            Riley Oest    Merge pull request #36 …
     feat/thing          2h   ↑ 3 ↓ 0  roest1        add the thing
```

`●` checked out, `⭐` default, `🛡` covered by a rule; `↑`/`↓` are ahead/behind
the default branch. A fetch runs in the background on open and the list
refreshes itself when it lands.

The preview: tracking state, the PR for this branch if there is one, the rules
that actually govern it — across every ruleset — and its recent commits.

| Key      | Does                                          |
| -------- | --------------------------------------------- |
| `enter`  | the branch menu (below)                       |
| `ctrl-o` | open on GitHub                                |
| `ctrl-k` | check it out                                  |
| `ctrl-x` | delete the remote branch (never the default; asks first) |
| `ctrl-s` | the rulesets editor                           |

The branch menu: 📥 Checkout · 🛡 Effective rules · 📜 Rulesets · ⭐ Set as
default · 🗑 Delete remote branch · ⚠️ Legacy classic protection · 🌐 Open.

### Rulesets, not classic branch protection

This changed for a reason worth knowing: the old version drove
`/repos/{o}/{r}/branches/{b}/protection`, and on a repo protected by a
*ruleset* that endpoint returns `404 Branch not protected`. So it reported
`main` as protected in the branch list — that field does account for rulesets
— and unprotected on the very next screen. It would also write a classic rule
*alongside* a ruleset, leaving two overlapping mechanisms and no clear answer
to "which one blocked my push".

**Effective rules** answers what actually governs a branch, across every
ruleset that targets it:

```
━━━ Effective rules: main ━━━

  from ruleset 20169814  (roest1/dotfiles)
    • deletion
    • non_fast_forward
    • pull_request  approvals=1  codeowners=true
    • required_status_checks  strict=true  checks=11

  ruleset 20169814 bypass: RepositoryRole/5:pull_request
```

The bypass line is the point. "Protected" means little on its own — with a
bypass you can merge red and stale, so the rules are guidance you override
rather than a wall. Without one, and with required approvals on a solo repo,
nothing can ever merge. Either way you want it on screen.

**Managing a ruleset** — pick one, then toggle the things worth toggling:

| Action                       | Notes                                                                 |
| ---------------------------- | --------------------------------------------------------------------- |
| View full ruleset            | rules, conditions and bypass list as JSON                             |
| Enforcement                  | `active` / `evaluate` / `disabled` — evaluate reports without blocking |
| Require branches up to date  | the `strict` flag; on, every merge invalidates every other open PR    |
| Required checks              | add / remove, picking from names CI actually reported                 |
| Bypass mode                  | `pull_request` (no direct pushes) or `always`                         |

**Required checks are picked, not typed.** The add-a-check picker offers only
names the last CI run reported, and the screen flags both directions of drift:

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

Nothing in here *creates* a classic protection rule. Rulesets supersede them,
and a branch carrying both is a branch where "why was this rejected" has two
possible answers. Legacy classic protection is read + delete only, for
migrating a repo off it.

Under the hood: writes are read-modify-write through a single helper, because
`PUT` replaces the fields it receives — every edit passes a `jq` filter over
the current ruleset rather than assembling a payload, so no edit can silently
drop a field. And rulesets update with **`PUT`, not `PATCH`**: `PATCH` returns
a bare `404` that reads exactly like a permissions failure and isn't.

---

## 🔑 Secrets

One list: 🔑 repository secrets, then 🌍 environment secrets, with when each
was last set. Values are **write-only** by design — GitHub never reveals them,
not even through the API — so the preview is the name, its scope, and how to
reference it.

| Key      | Does                                                                          |
| -------- | ----------------------------------------------------------------------------- |
| `enter`  | set this secret again — the only way to change a value                        |
| `ctrl-n` | set a new one: repository or environment, name, then the value typed hidden straight into `gh secret set` |
| `ctrl-x` | delete (asks first)                                                           |
| `ctrl-o` | the repo's secrets settings on GitHub                                         |

Names are upper-cased for you. Environment secrets resolve only in a job that
declares `environment: <name>`.

---

## 🌍 Environments

Deployment targets — each with its own secrets, required reviewers, wait timer
and branch policy. The preview shows the protection rules, the branch policy,
its secrets and its five most recent deployments.

| Key      | Does                                                    |
| -------- | ------------------------------------------------------- |
| `enter`  | configure: ⏱ wait timer · 👤 required reviewers · 🔑 set a secret here · 🗑 delete |
| `ctrl-n` | create — just a name                                    |
| `ctrl-x` | delete, after confirming — this removes its secrets too |
| `ctrl-o` | the repo's environments settings on GitHub              |
