# Setting up a new GitHub repository

My standard configuration for a new repo. Work top to bottom when creating one;

**Public vs. private.** Secret scanning and push protection are free on public
repos but require GitHub Advanced Security (paid) on private ones. Everything
else below applies to both.

---

## Creating a repository

- (self explanatory part)
- **Settings > General**

| Setting                                                                    | Value     | Notes                             |
| -------------------------------------------------------------------------- | --------- | --------------------------------- |
| **`General`**                                                              |           |                                   |
| Template repository                                                        | off       |                                   |
| **`Default branch`**                                                       |           |                                   |
| Default branch                                                             | `main`    |                                   |
| **`Releases`**                                                             |           |                                   |
| Enable release immutability                                                | off       |                                   |
| **`Social Preview`**                                                       |           |                                   |
| -------------------------------------------------------------------------- | --------- | --------------------------------- |
| **`Features`**                                                             |           |                                   |
| Wikis                                                                      | on        | turn off if docs live in the repo |
| (Wikis) restrict editing to collaborators only                             | on        |                                   |
| Issues                                                                     | on        |                                   |
| (Issues) permissions                                                       | All users |                                   |
| Sponsorships                                                               | off       |                                   |
| Preserve this repository (Archive Program)                                 | on        |                                   |
| Discussions                                                                | off       |                                   |
| Projects                                                                   | on        |                                   |
| Pull requests                                                              | All users |                                   |
| **`Pull Requests`**                                                        |           |                                   |
| Allow merge commits                                                        | on        |                                   |
| Allow squash merging                                                       | on        |                                   |
| Allow rebase merging                                                       | on        |                                   |
| Always suggest updating pull request branches                              | on        |                                   |
| Allow auto-merge                                                           | off       |                                   |
| Automatically delete head branches                                         | on        |                                   |
| **`Commits`**                                                              |           |                                   |
| Require contributors to sign off on web-based commits                      | off       |                                   |
| Allow comments on individual commits                                       | on        |                                   |
| **`Archives`**                                                             |           |                                   |
| Include Git LFS objects in archives                                        | off       |                                   |
| **`Pushes`**                                                               |           |                                   |
| Limit how many branches and tags can be updated in a single push (preview) | off       |                                   |
| **`Issues`**                                                               |           |                                   |
| Auto-close issues with merged linked pull requests                         | off       |                                   |

## Adding CI (Continuous Integration)

```bash
touch .github/CODEOWNERS
```

and get it onto the default branch.

CODEOWNERS file:

```
# Code owners for this repository.
#
# Every file is owned by @roest1, so any pull request requires his review when
# the `main` ruleset has "require review from Code Owners" enabled.
#
# Note on how this actually behaves here:
#
#   * Outside contributors have no write access — they fork, open a PR, and
#     cannot merge it. Only @roest1 can. That's GitHub's permission model, not
#     this file; CODEOWNERS just makes the review requirement explicit and
#     recorded on their PR.
#
#   * GitHub will not let anyone approve their own pull request. On a
#     single-maintainer repo that means @roest1's own PRs can never satisfy
#     "1 required approval" — he must be a bypass actor on the ruleset, or the
#     required approval count must be 0. Otherwise `main` is unmergeable by
#     anyone, including its owner.
#
# Last matching pattern wins, so more specific rules go below this line.

*   @roest1
```

```bash
touch .github/workflows/ci.yml
```

> CI needs to run at least once before status-checks can be configured in rulesets.

## Configuring dependabot updates

```bash
touch .github/dependabot.yml
```

---

## Creating a ruleset

One ruleset targeting the default branch.

| Setting                                                                           | Value                | Notes                                               |
| --------------------------------------------------------------------------------- | -------------------- | --------------------------------------------------- |
| **Enforcement**                                                                   | Active               |                                                     |
| **Bypass list**                                                                   | **Repository admin** |                                                     |
| **Target branches**                                                               | Default branch       | can also match by pattern: "main"                   |
| **`Rules`**                                                                       |                      |
| Restrict creations                                                                | off                  |                                                     |
| Restrict updates                                                                  | off                  |                                                     |
| Restrict deletions                                                                | on                   | protects the default branch                         |
| Require linear history                                                            | **off**              | merge commits are allowed                           |
| Requre deployments to succeed                                                     | off                  |                                                     |
| Require signed commits                                                            | `(depends)`          | see [Signed commits](#signed-commits-with-ssh-keys) |
| Require PR before merging                                                         | on                   |                                                     |
| → required approvals                                                              | 1                    |                                                     |
| → dismiss stale approvals on push                                                 | on                   |                                                     |
| → Require review from specific teams                                              | off                  |                                                     |
| → require review from code owners                                                 | on                   | needs `.github/CODEOWNERS`                          |
| → require approval of most recent push                                            | off                  |                                                     |
| → require conversation resolution                                                 | off                  | `(depends)`                                         |
| → require an additional approval for unattributed Copilot pull requests (preview) | off                  |                                                     |
| **Require status checks to pass**                                                 | **on**               | **`CHANGE`** — once CI exists                       |
| → require branches to be up to date before merging                                | **on**               | **`CHANGE`** — cheap when CI is fast; see below     |
| → do not require status checks on creation                                        | off                  | only matters for branch _patterns_                  |
| Block force pushes                                                                | on                   |                                                     |
| Require code scanning results                                                     | off                  | only meaningful if CodeQL is set up                 |
| Require code quality results                                                      | off                  |                                                     |
| Restrict code coverage                                                            | off                  |                                                     |
| Automatically request Copilot review                                              | off                  |                                                     |

### Why the bypass list is mandatory here

GitHub never lets anyone approve their own pull request. With `required
approvals: 1` and a sole maintainer, that means no PR can ever be merged —
including your own — unless you're on the bypass list. **Repository admin** on
the bypass list is what makes this configuration usable. This basically makes you BDFL.

It doesn't weaken anything for other people: outside contributors aren't admins,
and on a personal repo they have no write access, so they can't merge regardless.
The rule stays fully enforced for them.

`bypass_mode` has two settings:

- **`always`** — bypass on direct pushes and PRs.
- **`pull_request`** — bypass only within a PR, so you still open one.

Pick `pull_request` to keep yourself inside the PR flow; `always` if direct
pushes to the default branch should stay available. **`pull_request` here** — a
repo whose whole point is bootstrapping other machines should not be reachable by
`git push main` at 1am.

## Actions — `/settings/actions`

| Setting                                                                | Value                                             | Notes                              |
| ---------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------- |
| **Actions permissions**                                                | Allow all                                         | `(default)` — tighten if sensitive |
| Require actions to be pinned to a full-length commit SHA               | off                                               |                                    |
| **Artifact and log retention**                                         | 90 days                                           | `(default)`, max for public repos  |
| **Approval for running fork pull request workflows from contributors** | Require approval for first-time contributors      | **`CHANGE`** on public repos       |
| **Workflow permissions**                                               | Read repository contents and packages permissions | `(default)` — keep                 |
| Allow GitHub Actions to create and approve pull requests               | off                                               | `(default)`                        |

**Fork PR approval.** The default only gates _first-time_ contributors; after one
merged PR they can trigger workflows freely. Workflows run on your runners, so
prefer requiring approval for all outside collaborators on public repos.

**Workflow permissions.** Leave the token read-only and grant writes per job with
a `permissions:` block. Least privilege, and it's visible in the workflow file
rather than buried in settings.

---

## Security — `/settings/security_analysis`

| Setting                                                       | Value                                  |                                                                                                   |
| ------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Private vulnerability reporting**                           | **on**                                 | **`CHANGE`** for public repos — free, private disclosure channel                                  |
| Dependency graph                                              | on                                     | `(default)` on public repos                                                                       |
| Automatic dependency submission                               | on                                     | `(depends)`                                                                                       |
| **Dependabot alerts**                                         | **on**                                 | **`CHANGE`** — verify, it isn't always on                                                         |
| **`Dependabot Rules`**                                        |                                        |                                                                                                   |
| Dismiss low-impact alerts for development-scoped dependencies | on                                     | `(default)`                                                                                       |
| Dismiss package malware alerts                                | off                                    | `(defualt)`                                                                                       |
| Dependabot malware alerts                                     | **on**                                 | **`CHANGE`**                                                                                      |
| Dependabot security updates                                   | `(depends)`                            | auto-PRs for vulnerable dependencies                                                              |
| Grouped security updates                                      | on                                     | if using security updates — fewer PRs                                                             |
| Dependabot version updates                                    | `(depends)`                            | needs `.github/dependabot.yml`                                                                    |
| **`Code scanning`**                                           |                                        |                                                                                                   |
| Code scanning (CodeQL)                                        | `(depends)`                            | see below                                                                                         |
| Other tools                                                   |                                        | [workflows](https://github.com/roest1/dotfiles/actions/new?category=security&query=code+scanning) |
| Copilot Autofix                                               | on                                     | `(default)`                                                                                       |
| AI findings                                                   | off                                    | `(default)`                                                                                       |
| **`Protection rules`**                                        |                                        |                                                                                                   |
| Check runs failure threshold                                  | Security alert level: `High or higher` | Standard alert security level: `Only errors`                                                      |
| Secret Protection                                             | on                                     | `(default)` public; GHAS on private                                                               |
| Push protection                                               | on                                     | `(default)` public; GHAS on private                                                               |

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
