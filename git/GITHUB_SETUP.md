# Setting up a new GitHub repository

A checklist for configuring a new repo the way I want it. Verified against
`roest1/dotfiles` on 2026-08-01.

**Legend** — the thing the original draft was missing:

| Mark         | Meaning                                                            |
| ------------ | ------------------------------------------------------------------ |
| `(default)`  | GitHub's out-of-the-box value. Listed so you know you can skip it. |
| **`CHANGE`** | Differs from the default. You have to actually do something.       |
| `(depends)`  | Correct value depends on the repo — decide per project.            |

> **Public vs. private matters.** Several security features are free on public
> repos and require GitHub Advanced Security (paid) on private ones. Marked where
> it applies.

---

## Read this first: three traps

These are the ones that cost real time, so they're up front rather than buried.

### 1. You cannot approve your own pull request

GitHub blocks self-approval, always. So on a solo repo, `required approvals: 1`
means **nobody can merge anything, including you** — unless you're on the bypass
list. Adding CODEOWNERS makes it stricter, not looser.

Two ways out:

- **Bypass list → Repository admin** (what this repo does). Keeps the rule
  enforced for everyone else while unblocking you.
- **`required approvals: 0`.** Also unblocks you, but drops the recorded
  approval on outside PRs too.

Bypass doesn't weaken the outside-contributor case: they aren't admins, and on a
personal repo they have no write access anyway.

### 2. "Only I can merge" is already true — permissions, not rules

On a personal repo with no collaborators, nobody else can merge, ever. Outside
contributors fork and open a PR; merging needs write access. Branch rules don't
grant or restrict that. Don't build a ruleset trying to achieve something the
permission model already guarantees.

### 3. Linear history + merge method can silently destroy history

`Require linear history` forbids merge commits, which pushes you toward
**squash** — and squash collapses a branch into one commit. If that branch
carries history you deliberately preserved (e.g. a `git-filter-repo` migration
of another repo), squashing throws it away permanently.

If a branch is a fast-forward from the base, merge it from the CLI:

```sh
git checkout main && git merge --ff-only <branch> && git push origin main
```

`--ff-only` refuses rather than quietly creating a merge commit. GitHub's PR
button never fast-forwards.

---

## General settings — `/settings`

| Setting                                    | Value  |                                                     |
| ------------------------------------------ | ------ | --------------------------------------------------- |
| Template repository                        | off    | `(default)`                                         |
| Default branch                             | `main` | `(default)`                                         |
| Wikis                                      | on     | `(default)` — turn **off** if docs live in the repo |
| Issues                                     | on     | `(default)`                                         |
| Projects                                   | on     | `(default)`                                         |
| Discussions                                | off    | `(default)`                                         |
| Preserve this repository (Archive Program) | on     | `(default)`                                         |
| Sponsorships                               | off    | `(default)`                                         |

### Pull requests

| Setting                                | Value  |                               |
| -------------------------------------- | ------ | ----------------------------- |
| Allow merge commits                    | on     | `(default)`                   |
| Allow squash merging                   | on     | `(default)`                   |
| Allow rebase merging                   | on     | `(default)`                   |
| Always suggest updating PR branches    | off    | `(default)`                   |
| Allow auto-merge                       | off    | `(default)`                   |
| **Automatically delete head branches** | **on** | **`CHANGE`** — default is off |

> If you enable `Require linear history` in the ruleset, allowing merge commits
> here is contradictory: the rule will reject what the button offers. Consider
> narrowing to squash + rebase — but see trap 3 first, because squash is
> destructive for branches carrying preserved history.

### Commits / archives / issues

| Setting                                  | Value |             |
| ---------------------------------------- | ----- | ----------- |
| Require sign-off on web-based commits    | off   | `(default)` |
| Allow comments on individual commits     | on    | `(default)` |
| Include Git LFS objects in archives      | off   | `(default)` |
| Auto-close issues from merged linked PRs | on    | `(default)` |

---

## Rules — `/settings/rules`

Create one ruleset targeting the default branch.

| Setting                                | Value                  |                                            |
| -------------------------------------- | ---------------------- | ------------------------------------------ |
| Enforcement                            | Active                 | **`CHANGE`** — new rulesets start Disabled |
| **Bypass list**                        | **Repository admin**   | **`CHANGE`** — see trap 1                  |
| Target branches                        | Default branch         |                                            |
| Restrict creations                     | off                    |                                            |
| Restrict updates                       | off                    |                                            |
| Restrict deletions                     | on                     | protects `main` from deletion              |
| Require linear history                 | on                     | `(depends)` — see trap 3                   |
| Require signed commits                 | off                    | `(depends)` — on if you sign               |
| Block force pushes                     | on                     |                                            |
| Require PR before merging              | on                     |                                            |
| → required approvals                   | 1                      | **only viable with a bypass actor**        |
| → dismiss stale approvals on push      | on                     |                                            |
| → require review from code owners      | on                     | needs `.github/CODEOWNERS`                 |
| → require approval of most recent push | off                    | would re-block you                         |
| → require conversation resolution      | off                    | `(depends)`                                |
| **Require status checks to pass**      | **on, once CI exists** | **`CHANGE`** — see below                   |
| Require deployments to succeed         | off                    |                                            |
| Require code scanning results          | off                    | only if CodeQL is set up                   |
| Automatically request Copilot review   | off                    |                                            |

### Status checks are the rule that actually earns its keep

The original draft had this **off**, and it's the most valuable rule available
once a repo has CI. An approval on a solo repo is a formality you bypass anyway;
a required status check is a real gate that has caught real bugs.

Caveat: the check names only appear in the picker **after a workflow has run at
least once**. So the order is: push CI → let it run → then add the required
checks. Don't try to configure it before the first run.

### CODEOWNERS

`.github/CODEOWNERS` (also valid at the repo root or in `docs/`):

```
*   @roest1
```

Only the copy **on the default branch** has any effect. The PR that first adds it
won't have an owner assigned — that's expected, not a misconfiguration.

---

## Actions — `/settings/actions`

| Setting                        | Value                                              |                                              |
| ------------------------------ | -------------------------------------------------- | -------------------------------------------- |
| Actions permissions            | Allow all                                          | `(default)` — tighten for anything sensitive |
| Log retention                  | 90 days                                            | `(default)`, and the max for public repos    |
| Fork PR approval               | **Require approval for all outside collaborators** | **`CHANGE`** on public repos                 |
| Workflow permissions           | Read repository contents                           | `(default)` — keep it                        |
| Actions can create/approve PRs | off                                                | `(default)`                                  |

> **Fork PR approval matters on public repos.** The default only gates
> _first-time_ contributors; after one merged PR they can trigger workflows
> freely. Since workflows run on your runners with your secrets, prefer
> requiring approval for all outside collaborators.

> Leave workflow permissions read-only. Grant write per-job with a `permissions:`
> block instead — least privilege, and it's visible in the workflow file.

---

## Security — `/settings/security_analysis`

| Setting                             | Value                        |                                                                                                     |
| ----------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------- |
| **Private vulnerability reporting** | **on**                       | **`CHANGE`** for public repos — free, gives researchers a private channel instead of a public issue |
| Dependency graph                    | on                           | `(default)` on public repos                                                                         |
| Automatic dependency submission     | on                           | `(depends)`                                                                                         |
| Dependabot alerts                   | **on**                       | **`CHANGE`** — was off on this repo                                                                 |
| Dependabot security updates         | `(depends)`                  | auto-PRs for vulnerable deps                                                                        |
| Dependabot version updates          | `(depends)`                  | needs `.github/dependabot.yml`                                                                      |
| Grouped security updates            | on if using security updates | fewer PRs                                                                                           |
| Secret scanning                     | on                           | `(default)` on **public**; needs GHAS on private                                                    |
| Push protection                     | on                           | `(default)` on **public**; needs GHAS on private                                                    |
| Code scanning (CodeQL)              | `(depends)`                  | see below                                                                                           |

### Dependabot only sees ecosystems it can parse

It reads `package.json`, `Cargo.toml`, `requirements.txt`, `go.mod`, `Gemfile`,
and `.github/workflows/*.yml`. It does **not** read custom formats.

For this repo that means it covers exactly one thing — GitHub Actions versions —
and is blind to `deps.conf` and `nvim/lazy-lock.json`, which are the actual
dependency surface. That's still worth having: `actions/checkout@v4` started
emitting a Node 20 deprecation on every run and needed a manual bump.

Before enabling version updates on a new repo, check whether it has a manifest
Dependabot understands. If it doesn't, the config is decoration.

### CodeQL is language-gated

Supports C/C++, C#, Go, Java/Kotlin, JavaScript/TypeScript, Python, Ruby, Swift
(Rust in preview). It does **not** support bash or Lua — so on a shell/config
repo it scans nothing and `Require code scanning results` would be meaningless.

Enable it on application repos; skip it on config repos.

---

## Order of operations for a new repo

1. Create the repo, push an initial commit — rules need a branch to target.
2. General settings: enable **auto-delete head branches**.
3. Add `.github/CODEOWNERS` and merge it to the default branch.
4. Add CI and let it run once, so the check names exist.
5. Create the ruleset — including **Repository admin on the bypass list** and the
   status checks from step 4.
6. Security: private vulnerability reporting, Dependabot alerts; add
   `.github/dependabot.yml` if there's a manifest it can read.
7. Verify from the CLI rather than trusting the UI:

```sh
gh api repos/<user>/<repo> --jq '.security_and_analysis'
gh api repos/<user>/<repo>/rulesets
gh api repos/<user>/<repo>/vulnerability-alerts   # 204 = on, 404 = off
```

That last step is how the mistakes above were found: the UI showed what was
_intended_, the API showed what was actually stored.
