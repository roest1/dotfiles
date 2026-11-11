# Setting up a new GitHub repository

My standard configuration for a new repo. Work top to bottom when creating one.
The order matters in one place: a status check has to report once before a
ruleset can require it, so CI lands before the rulesets.

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

### End the workflow with a `ci ok` job

The `main-ci` ruleset below requires this one job and nothing else. Copy it in
as the last job, and list every other job id in `needs`:

```yaml
  ci-ok:
    name: ci ok
    if: always()                  # without it, a failed job SKIPS this one,
    needs: [lint, test, build]    # and a skipped required check counts as passing
    runs-on: ubuntu-latest
    steps:
      - name: Every job succeeded
        env:
          NEEDS: ${{ toJSON(needs) }}
        run: |
          jq -r 'to_entries[] | "\(.value.result)\t\(.key)"' <<<"$NEEDS"
          jq -e 'all(.[]; .result == "success")' <<<"$NEEDS" >/dev/null
```

`dotfiles`' version also fails when a job in `ci.yml` is missing from `needs`,
so a new job cannot run without gating anything. Copy that step from
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) too.

**No `paths` or `paths-ignore` on the `pull_request` trigger.** A workflow that
doesn't run never reports `ci ok`, so a docs-only PR would wait on a required
check forever. To skip work on docs-only changes, skip steps inside the jobs
and let `ci ok` still report.

## Configuring dependabot updates

```bash
touch .github/dependabot.yml
```

Give every ecosystem a `cooldown`, so Dependabot proposes a release only after
it is a week old. A hijacked release is usually caught within its first few
days:

```yaml
    cooldown:
      default-days: 7
```

---

## Creating the rulesets

Two rulesets target the default branch:

- **`main-branch-rules`** holds the review requirement. A sole maintainer can only
  meet it by bypassing, so it lists Repository admin as a bypass actor.
- **`main-ci`** holds the CI gate. It has no bypass actors at all.

They are split because a bypass applies only to the ruleset that lists it, and
GitHub enforces every ruleset that matches the branch. With one ruleset, the bypass
every merge needs also skipped every required check, so CI was advisory: green
before merging was a habit, not a rule. With two, ticking "bypass" gets you past
the review and nothing else, and the merge button stays disabled until `ci ok`
passes.

Both rulesets block deletion and force pushes. The overlap is harmless, and either
one alone still protects `main` if the other is disabled.

### `main-branch-rules`

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
| Require deployments to succeed                                                    | off                  |                                                     |
| Require signed commits                                                            | `(depends)`          | see [SSH keys](#ssh-keys-auth-and-signing)          |
| Require PR before merging                                                         | on                   |                                                     |
| → required approvals                                                              | 1                    |                                                     |
| → dismiss stale approvals on push                                                 | on                   |                                                     |
| → Require review from specific teams                                              | off                  |                                                     |
| → require review from code owners                                                 | on                   | needs `.github/CODEOWNERS`                          |
| → require approval of most recent push                                            | off                  |                                                     |
| → require conversation resolution                                                 | off                  | `(depends)`                                         |
| → require an additional approval for unattributed Copilot pull requests (preview) | off                  |                                                     |
| Require status checks to pass                                                     | off                  | lives in `main-ci`, below                           |
| Block force pushes                                                                | on                   |                                                     |
| Require code scanning results                                                     | off                  | only meaningful if CodeQL is set up                 |
| Require code quality results                                                      | off                  |                                                     |
| Restrict code coverage                                                            | off                  |                                                     |
| Automatically request Copilot review                                              | off                  |                                                     |

### `main-ci`

| Setting                                            | Value                | Notes                                          |
| -------------------------------------------------- | -------------------- | ---------------------------------------------- |
| **Enforcement**                                    | Active               |                                                |
| **Bypass list**                                    | **empty**            | the point of the split                         |
| **Target branches**                                | Default branch       | an empty target list matches no branch at all  |
| Restrict deletions                                 | on                   |                                                |
| Block force pushes                                 | on                   |                                                |
| **Require status checks to pass**                  | **on**               | one check: **`ci ok`**, source GitHub Actions  |
| → require branches to be up to date before merging | **on**               | otherwise CI tested the PR on an older `main`  |
| → do not require status checks on creation         | off                  |                                                |

**Require `ci ok` and nothing else.** Required checks are job *names* typed into
the ruleset, and GitHub never updates the list. In `dotfiles` the list still
required `install (fedora / dnf)` after #96 renamed that job, so that check never
reported. It also missed four jobs added later. Nobody noticed, because every merge
was a bypass. With one stable name, adding or renaming a job needs no ruleset
edit.

**Create it disabled, then switch it on.** `ci ok` has to report once before the
ruleset UI offers it. Merge the PR that adds the job first, then pick the check
and set enforcement to Active. Check the target before you do: a ruleset with an
empty target list saves without complaint and protects nothing.

### Check the live settings

The UI spreads a ruleset over one long page. This prints both rulesets in a few
lines, to compare against the tables above:

```bash
repo=roest1/dotfiles
for id in $(gh api repos/$repo/rulesets --jq '.[].id'); do
  gh api repos/$repo/rulesets/$id --jq '{name, enforcement,
    target: .conditions.ref_name.include,
    bypass: [.bypass_actors[] | "\(.actor_type):\(.bypass_mode)"],
    rules:  [.rules[] | .type],
    checks: [.rules[] | select(.type == "required_status_checks")
             | .parameters.required_status_checks[].context]}'
done
```

### Why the bypass list is mandatory here

GitHub never lets anyone approve their own pull request. With `required
approvals: 1` and a sole maintainer, that means no PR can ever be merged —
including your own — unless you're on the bypass list. **Repository admin** on
the bypass list is what makes this configuration usable. This basically makes you BDFL.

It doesn't weaken anything for other people: outside contributors aren't admins,
and on a personal repo they have no write access, so they can't merge regardless.
The rule stays fully enforced for them.

Keep the bypass in `main-branch-rules` only. Added to `main-ci`, it would make CI
advisory again.

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
| Dismiss package malware alerts                                | off                                    | `(default)`                                                                                       |
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

### Dependabot only parses ecosystems it recognizes

`package.json` (npm, yarn, pnpm, bun), `Cargo.toml`, `requirements.txt`,
`pyproject.toml`, `go.mod`, `Gemfile`, `composer.json`, and
`.github/workflows/*.yml`. Custom dependency formats and lockfiles from other
tools are invisible to it. `mise.toml` is one of those, which is why `dotfiles`
also runs Renovate (below).

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
self-approval — the code-owner requirement works normally, and they merge
without the bypass. They still wait on `ci ok` like any other PR.

### Renovate, for what Dependabot can't read

Only when a repo pins something Dependabot has no ecosystem for (`dotfiles`:
the `mise.toml` tools). Renovate is a GitHub App run by Mend, a third party,
with read/write access to code and pull requests on the repos you give it.
Put every Renovate setting in a committed `renovate.json`, and turn off every
manager Dependabot already covers (`enabledManagers`), so the two bots never
open the same PR.

| Step                              | Choice                                  | Notes                                                    |
| --------------------------------- | --------------------------------------- | -------------------------------------------------------- |
| GitHub app install                | **Only select repositories**            | never "All repositories"                                 |
| Mend: product                     | **Renovate Only**                       | "Mend Application Security" needs a paid license         |
| Mend: mode                        | **Scan and Alert**                      | the default, "Scan Only", sets Renovate to silent: no PRs |
| `renovate.json`: automerge        | off (the default)                       | a bot PR still needs your merge                          |
| `renovate.json`: release age      | `"minimumReleaseAge": "7 days"`         | matches Dependabot's cooldown                            |

A repo that already has `renovate.json` gets no onboarding PR. Renovate goes
straight to its schedule.

### CodeQL is language-gated

Supports C/C++, C#, Go, Java/Kotlin, JavaScript/TypeScript, Python, Ruby, Swift,
and Rust (preview). It does **not** support shell or Lua, so on a config or
dotfiles repo it scans nothing and `Require code scanning results` would be
meaningless. Enable it on application repos; skip it elsewhere.

---

## SSH keys: auth and signing

One key per machine. Git authenticates to GitHub with it, so no token is stored
for git. `gh` keeps its own login, separate from git's.

```bash
ssh-keygen -t ed25519 -C "<user>@<machine>"
gh auth refresh -h github.com -s admin:public_key     # temporary scope, to upload the key
gh ssh-key add ~/.ssh/id_ed25519.pub --title "<machine>"
ssh -T git@github.com                                 # expect: Hi <user>!
gh config set -h github.com git_protocol ssh
gh auth refresh -h github.com -r admin:public_key     # drop the scope again
```

- **Answer No when gh asks "Authenticate Git with your GitHub credentials?"**
  `gh auth login` and `gh auth refresh` both ask. Yes runs `gh auth setup-git`,
  which writes a credential helper into `~/.gitconfig`, a tracked file in
  `dotfiles`. It also sets this host's `git_protocol` back to `https`.
- **Set `git_protocol` with `-h github.com`.** The per-host value overrides the
  global one, so a plain `gh config set git_protocol ssh` can read `ssh` while
  `gh auth status` still says `https`.
- **No credential helper in `git/gitconfig`.** Its `insteadOf` rules send only
  your own owners' repos over SSH, so public clones still work on a machine with
  no key. See the comments in [`gitconfig`](gitconfig). CI rejects a credential
  helper.
- **A new machine needs its key on GitHub before it pulls `dotfiles` after
  `make link`.** `bootstrap.sh` clones over HTTPS, so the first clone works
  without one.
- **Port 22 blocked** (some work networks): GitHub also serves SSH on port 443
  at `ssh.github.com`. Add this to `~/.ssh/config`:

  ```
  Host github.com
      HostName ssh.github.com
      Port 443
      User git
  ```

- **Passphrase or not.** Without a passphrase, anyone who can read `~/.ssh` can use
  the key, the same exposure as `gh`'s token in `~/.config/gh/hosts.yml`. With
  one, you need an agent, and background fetches (`git-autofetch`) fail while
  the key is locked.

### Signing commits with the same key

```bash
gh auth refresh -h github.com -s admin:ssh_signing_key
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "<machine> signing"
gh auth refresh -h github.com -r admin:ssh_signing_key
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

GitHub registers authentication keys and signing keys separately, even when they
are the same key. In `dotfiles` the three `git config` lines land in the tracked
`git/gitconfig`, so every linked machine then needs a key at that path before it
can commit. Turn on **Require signed commits** in `main-branch-rules` only after
every machine you commit from signs.

