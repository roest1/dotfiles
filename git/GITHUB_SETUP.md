# Setting up a new GitHub repository

My standard configuration for a new repo. Work top to bottom when creating one;
use the [verification commands](#verify-from-the-cli) to audit an existing one.

**Legend**

| Mark         | Meaning                                                          |
| ------------ | ---------------------------------------------------------------- |
| `(default)`  | GitHub's out-of-the-box value — nothing to do.                    |
| **`CHANGE`** | Differs from the default. Requires action.                        |
| `(depends)`  | Decide per repo.                                                  |

**Public vs. private.** Secret scanning and push protection are free on public
repos but require GitHub Advanced Security (paid) on private ones. Everything
else below applies to both.

---

## Order of operations

Some steps depend on earlier ones, so the sequence matters:

1. Create the repo and push an initial commit — rules need a branch to target.
2. **General settings**: enable auto-delete head branches.
3. Add `.github/CODEOWNERS` and get it onto the default branch. Only the copy on
   the default branch has any effect.
4. Add CI and let it run once. Status-check names don't appear in the ruleset
   picker until a workflow has reported them at least once.
5. Create the ruleset, including the bypass list and the status checks from
   step 4.
6. Security settings and `.github/dependabot.yml`.
7. Verify with the CLI.

---

## General settings — `/settings`

| Setting                                    | Value  |                                                     |
| ------------------------------------------ | ------ | --------------------------------------------------- |
| Template repository                        | off    | `(default)`                                         |
| Default branch                             | `main` | `(default)`                                         |
| Wikis                                      | on     | `(default)` — turn off if docs live in the repo     |
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

**Choosing a merge method.** All three stay enabled, because the right one
depends on the branch:

- **Merge commit** — preserves every commit and the branch shape. Use when the
  branch's history is worth keeping.
- **Squash** — collapses the branch into one commit. Fine for a short feature
  branch; destructive for a branch carrying history you deliberately preserved,
  such as another repo imported with `git-filter-repo`.
- **Rebase** — replays commits onto the base, rewriting every hash.

When a branch is a fast-forward from the base and the exact history matters,
merge from the CLI instead of the web button, which never fast-forwards:

```sh
git checkout main && git merge --ff-only <branch> && git push origin main
```

`--ff-only` refuses rather than silently creating a merge commit.

### Commits / archives / issues

| Setting                                  | Value |             |
| ---------------------------------------- | ----- | ----------- |
| Require sign-off on web-based commits    | off   | `(default)` |
| Allow comments on individual commits     | on    | `(default)` |
| Include Git LFS objects in archives      | off   | `(default)` |
| Auto-close issues from merged linked PRs | on    | `(default)` |

---

## Ruleset — `/settings/rules`

One ruleset targeting the default branch.

| Setting                                | Value                  |                                            |
| -------------------------------------- | ---------------------- | ------------------------------------------ |
| Enforcement                            | Active                 | **`CHANGE`** — new rulesets start Disabled |
| **Bypass list**                        | **Repository admin**   | **`CHANGE`** — required, see below         |
| Target branches                        | Default branch         |                                            |
| Restrict creations                     | off                    |                                            |
| Restrict updates                       | off                    |                                            |
| Restrict deletions                     | on                     | protects the default branch                |
| Require linear history                 | **off**                | merge commits are allowed                  |
| Require signed commits                 | `(depends)`            | see [Signed commits](#signed-commits-with-ssh-keys) |
| Block force pushes                     | on                     |                                            |
| Require PR before merging              | on                     |                                            |
| → required approvals                   | 1                      |                                            |
| → dismiss stale approvals on push      | on                     |                                            |
| → require review from code owners      | on                     | needs `.github/CODEOWNERS`                 |
| → require approval of most recent push | off                    |                                            |
| → require conversation resolution      | off                    | `(depends)`                                |
| **Require status checks to pass**      | **on**                 | **`CHANGE`** — once CI exists              |
| Require deployments to succeed         | off                    |                                            |
| Require code scanning results          | off                    | only meaningful if CodeQL is set up        |
| Automatically request Copilot review   | off                    |                                            |

### Why the bypass list is mandatory here

GitHub never lets anyone approve their own pull request. With `required
approvals: 1` and a sole maintainer, that means no PR can ever be merged —
including your own — unless you're on the bypass list. **Repository admin** on
the bypass list is what makes this configuration usable.

It doesn't weaken anything for other people: outside contributors aren't admins,
and on a personal repo they have no write access, so they can't merge regardless.
The rule stays fully enforced for them.

`bypass_mode` has two settings:

- **`always`** — bypass on direct pushes and PRs.
- **`pull_request`** — bypass only within a PR, so you still open one.

Pick `pull_request` to keep yourself inside the PR flow; `always` if direct
pushes to the default branch should stay available.

### Status checks

The most valuable rule in the list once a repo has CI — an approval you bypass is
a formality, a required check is an actual gate.

Add each check **by exact name**; there's no wildcard. Two consequences:

- Names only appear in the picker after a workflow has reported them once, so CI
  has to run before this can be configured.
- If a check is renamed, the required check stops reporting. A check that never
  reports doesn't fail the PR — it blocks it indefinitely waiting for a status
  that will never arrive. Give matrix jobs stable literal names rather than
  interpolating runner labels:

```yaml
# fragile — the check name changes if you pin the runner
name: build (${{ matrix.os }})

# stable
name: build (${{ matrix.name }})
strategy:
  matrix:
    include:
      - name: linux
        os: ubuntu-latest
```

Require every check that is fast and deterministic. Checks that hit third-party
package mirrors are worth requiring too, but they're the first to demote if one
starts failing for reasons outside the repo.

---

## CODEOWNERS

`.github/CODEOWNERS` — also valid at the repo root or in `docs/`:

```
*   @roest1
```

Sole owner of every path, which combined with `require review from code owners`
means **anyone who forks and opens a PR needs my approval before it can reach the
default branch**.

Notes:

- Only the copy on the **default branch** takes effect. The PR that first adds
  the file won't have an owner assigned — expected, not a misconfiguration.
- Last matching pattern wins, so put more specific rules below the catch-all.
- A username here must have access to the repo, or the rule silently matches
  nobody.

---

## Signed commits with SSH keys

Signing works with the SSH key you already use for auth — no GPG needed. Requires
git ≥ 2.34.

```sh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

Then register the key on GitHub as a **signing key**:
`Settings → SSH and GPG keys → New SSH key → Key type: Signing Key`.

**The same key must be added twice** — once as an Authentication Key, once as a
Signing Key. They're separate lists. Skipping the second one is the usual reason
commits show as Unverified despite being signed locally.

Verify:

```sh
git log --show-signature -1          # local signature
gh api repos/<user>/<repo>/commits/<sha> --jq '.commit.verification'
```

**Before enabling `Require signed commits` on a public repo**, note that it
applies to everyone: an outside contributor whose commits aren't signed cannot
have their PR merged, and most casual contributors don't have signing configured.
On a repo that rarely takes outside PRs that's an acceptable trade; on one
courting contributions it's a real barrier. Web-based commits and merges made
through GitHub's UI are signed by GitHub's own key and count as verified.

---

## Actions — `/settings/actions`

| Setting                          | Value                                              |                                  |
| -------------------------------- | -------------------------------------------------- | -------------------------------- |
| Actions permissions              | Allow all                                          | `(default)` — tighten if sensitive |
| Log retention                    | 90 days                                            | `(default)`, max for public repos |
| **Fork PR approval**             | **Require approval for all outside collaborators** | **`CHANGE`** on public repos     |
| Workflow permissions             | Read repository contents                           | `(default)` — keep               |
| Actions can create/approve PRs   | off                                                | `(default)`                      |

**Fork PR approval.** The default only gates *first-time* contributors; after one
merged PR they can trigger workflows freely. Workflows run on your runners, so
prefer requiring approval for all outside collaborators on public repos.

**Workflow permissions.** Leave the token read-only and grant writes per job with
a `permissions:` block. Least privilege, and it's visible in the workflow file
rather than buried in settings.

---

## Security — `/settings/security_analysis`

| Setting                             | Value       |                                                          |
| ----------------------------------- | ----------- | -------------------------------------------------------- |
| **Private vulnerability reporting** | **on**      | **`CHANGE`** for public repos — free, private disclosure channel |
| Dependency graph                    | on          | `(default)` on public repos                              |
| Automatic dependency submission     | on          | `(depends)`                                              |
| **Dependabot alerts**               | **on**      | **`CHANGE`** — verify, it isn't always on                |
| Dependabot security updates         | `(depends)` | auto-PRs for vulnerable dependencies                     |
| Grouped security updates            | on          | if using security updates — fewer PRs                    |
| Dependabot version updates          | `(depends)` | needs `.github/dependabot.yml`                           |
| Secret scanning                     | on          | `(default)` public; GHAS on private                      |
| Push protection                     | on          | `(default)` public; GHAS on private                      |
| Code scanning (CodeQL)              | `(depends)` | see below                                                |

### Dependabot only parses ecosystems it recognises

`package.json`, `Cargo.toml`, `requirements.txt`, `pyproject.toml`, `go.mod`,
`Gemfile`, `composer.json`, and `.github/workflows/*.yml`. Custom dependency
formats and lockfiles from other tools are invisible to it.

Before enabling version updates, check the repo actually has a manifest it can
read — otherwise the config is decoration. A repo with no supported manifest
still benefits from the `github-actions` ecosystem alone, since action versions
go stale on their own schedule:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"
```

Dependabot's PRs come from `dependabot[bot]`, so approving them isn't
self-approval — the code-owner requirement works normally.

### CodeQL is language-gated

Supports C/C++, C#, Go, Java/Kotlin, JavaScript/TypeScript, Python, Ruby, Swift,
and Rust (preview). It does **not** support shell or Lua, so on a config or
dotfiles repo it scans nothing and `Require code scanning results` would be
meaningless. Enable it on application repos; skip it elsewhere.

---

## Verify from the CLI

The settings UI shows what's intended; the API shows what's actually stored.
Check the API when something isn't behaving as expected.

```sh
R=<user>/<repo>

# merge behaviour, features, visibility
gh api repos/$R --jq '{visibility, delete_branch_on_merge, allow_auto_merge,
                       allow_merge_commit, allow_squash_merge, allow_rebase_merge}'

# secret scanning, push protection, dependabot
gh api repos/$R --jq '.security_and_analysis'

# 204 = enabled, 404 = disabled
gh api repos/$R/vulnerability-alerts

# rulesets, then the rules and bypass list of one
gh api repos/$R/rulesets
gh api repos/$R/rulesets/<id> --jq '{rules: [.rules[].type], bypass: .bypass_actors,
                                     can_bypass: .current_user_can_bypass}'

# which checks a workflow reports, to match required-check names exactly
gh run view <run-id> --repo $R --json jobs --jq '.jobs[].name'
```

Enabling the two Dependabot toggles from the CLI:

```sh
gh api -X PUT repos/$R/vulnerability-alerts
gh api -X PUT repos/$R/automated-security-fixes
```
