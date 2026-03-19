# GitHub Terminal Tools

Interactive GitHub management from the terminal — no browser needed for most workflows.

> **6 commands. That's it.** Each opens an interactive screen you navigate with arrow keys.

| Command     | What it does                              |
| ----------- | ----------------------------------------- |
| `gha-ui`    | CI/CD workflows → logs → rerun            |
| `gpr`       | Full PR lifecycle (create, review, merge) |
| `ghsecrets` | Repo + environment secrets                |
| `ghbranch`  | Branch management + protection rules      |
| `ghenv`     | Deployment environments                   |
| `gha`       | Quick workflow status (non-interactive)   |

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

## gha-ui — CI/CD Workflow Viewer + Logs

Pick a workflow → action menu → smart logs or step browser.

<!-- Replace with your asciinema recording -->
<!-- [![gha-ui demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

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

<!-- [![step browser demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

---

## gpr — Pull Request Management

Full PR lifecycle without leaving the terminal.

<!-- [![gpr demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

### Creating a PR

```sh
gpr create    # walks you through draft/ready, opens gh's interactive flow
```

### PR list + actions

```sh
gpr           # list all open PRs with live preview pane
gpr mine      # filtered to your PRs
```

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
| 🏷 Manage labels     | Add/remove from repo's label list         |
| 👤 Request reviewers | Pick from collaborators                   |
| ✏️ Edit title/body   | Rename or rewrite description             |
| 🔀 Merge             | Strategy picker (squash/merge/rebase)     |
| ❌ Close PR          | Close without merging                     |
| 🌐 Open in browser   | Fallback to GitHub UI                     |
| 🔍 View CI checks    | Pass/fail status, refreshable             |

Most actions loop back to the menu — do multiple things on the same PR without re-running the command.

### Merge flow

Picks strategy → asks about branch deletion → merges. Checks for conflicts first.

<!-- [![gpr merge demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

---

## ghsecrets — Secrets Management

<!-- [![ghsecrets demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

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

## ghbranch — Branch Management + Protection

<!-- [![ghbranch demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

### Listing branches

Shows protection status at a glance:

```
━━━ Branches ━━━

  🛡  main  (protected)
     feature/new-login
     fix/api-timeout
```

### Setting protection rules

Interactive wizard — no JSON or API flags to remember:

```
━━━ Configure protection for 'main' ━━━

Required approving reviews (0-6, default 0): 1
Dismiss stale reviews on new push? (Y/n): y
Require status checks to pass before merging? (y/N): y
Enforce rules for admins too? (y/N): n
Require linear history? (y/N): y

✅ Protection rules applied to 'main'
```

### Other actions

| Action                | What it does                               |
| --------------------- | ------------------------------------------ |
| View protection rules | Structured view of what's enforced         |
| Remove protection     | Strip all rules (with confirmation)        |
| Delete remote branch  | Safety check — won't delete default branch |
| Set default branch    | Change repo's default                      |

---

## ghenv — Environment Management

<!-- [![ghenv demo](https://asciinema.org/a/XXXXXX.svg)](https://asciinema.org/a/XXXXXX) -->

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

## Recording Guide

All demos are recorded with [asciinema](https://asciinema.org).

### Install

```sh
brew install asciinema
# or
pip install asciinema
```

### Recording tips

```sh
# Start recording (saves locally)
asciinema rec demos/gha-ui.cast

# When done, press Ctrl+D or type exit

# Play it back to check
asciinema play demos/gha-ui.cast

# Upload to asciinema.org (gives you a URL)
asciinema upload demos/gha-ui.cast
```

Keep recordings tight: resize your terminal to ~100x30 before recording so it renders well on GitHub. Use `--idle-time-limit=2` to cap pauses.

```sh
asciinema rec --idle-time-limit=2 demos/gha-ui.cast
```

### What to record

Record each demo separately. Keep each under 60 seconds. Here's the sequence:

#### 1. `gha-ui` — the flagship demo (~45s)

This is the most impressive one. Record this first.

```
Pre-setup:
  Have a repo with at least one workflow that has a recent run
  (ideally one with a failure to show the auto-expand)

Script:
  1. gha-ui
  2. Pick a workflow with ❌
  3. Select "Smart log view"
  4. Scroll through — show collapsed passes, expanded failure
  5. Press q to exit less
  6. Press r to refresh
  7. Press - to go back to action menu
  8. Select "Browse steps interactively"
  9. Arrow through a few steps (show preview pane updating)
  10. Enter on the failed step → full log in less
  11. q out, esc out, - back, q to exit
```

#### 2. `gpr` — PR lifecycle (~50s)

```
Pre-setup:
  Create a feature branch with a small change
  Push it but don't create the PR yet

Script:
  1. gpr create
  2. Pick "Draft"
  3. Fill in title/body via gh's interactive flow
  4. gpr (list PRs — your new one appears)
  5. Arrow to it (show preview pane)
  6. Enter → action menu
  7. "View diff" → scroll a bit → q
  8. "View file changes" → pick a file → show preview → esc
  9. "Approve" (if you have a second PR from someone else)
  10. - to exit
```

#### 3. `ghsecrets` — quick and clean (~25s)

```
Script:
  1. ghsecrets
  2. "Set repo secret"
  3. Type: DEMO_KEY → paste a value
  4. Back to menu (auto-returns)
  5. "List repo secrets" — show it appeared
  6. r to refresh
  7. - back
  8. "Delete repo secret" → pick DEMO_KEY → confirm
  9. q to exit
```

#### 4. `ghbranch` — protection rules (~30s)

```
Pre-setup:
  Have at least 2 branches (main + one feature branch)

Script:
  1. ghbranch
  2. "List branches" — show 🛡 indicators
  3. - back
  4. "Set protection rules"
  5. Pick main
  6. Set: 1 review, dismiss stale, require checks
  7. Back to menu (auto-returns)
  8. "View protection rules" → pick main → show the JSON
  9. r to refresh → - back
  10. "Remove protection" → pick main → confirm
  11. q to exit
```

#### 5. `ghenv` — environment lifecycle (~30s)

```
Script:
  1. ghenv
  2. "Create environment" → type "staging"
  3. Back to menu
  4. "Set wait timer" → pick staging → 5 minutes
  5. Back to menu
  6. "View environment details" → pick staging → show timer + empty secrets
  7. r to refresh → - back
  8. "Delete environment" → pick staging → confirm
  9. q to exit
```

#### 6. Navigation patterns (~15s, optional)

```
Show the navigation feel across different screens:

  1. ghsecrets → arrow down → enter (select action)
  2. - to go back to menu
  3. q to exit entirely
  4. ghbranch → same pattern
  5. Quick cuts showing the consistency
```

### After recording

1. Create a `demos/` directory in dotfiles
2. Upload each `.cast` file to asciinema.org
3. Replace the `<!-- comment -->` blocks in this file with the embed links:

```md
[![gha-ui demo](https://asciinema.org/a/YOUR_ID.svg)](https://asciinema.org/a/YOUR_ID)
```

Alternatively, convert to GIF for inline rendering on GitHub:

```sh
# Install agg (asciinema gif generator)
brew install asciinema/tap/agg

# Convert
agg demos/gha-ui.cast demos/gha-ui.gif

# Then reference in markdown
# ![gha-ui demo](demos/gha-ui.gif)
```

GIFs render inline on GitHub without clicking through. `.cast` files require the asciinema player. GIFs are larger but more convenient for readers.
