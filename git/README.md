# Git Reference

## Table of Contents

1. [Initial Setup](#initial-setup)
   - [Set Credentials](#set-credentials)
   - [Setup SSH Keys](#setup-ssh-keys)
2. [Creating a Repository](#creating-a-repository)
   - [Initialize Locally](#initialize-locally)
   - [Connect to a Remote](#connect-to-a-remote)
3. [Managing Remotes](#managing-remotes)
   - [Update a Remote URL](#update-a-remote-url)
4. [Branching and Daily Workflow](#branching-and-daily-workflow)
   - [Create or Switch to a Branch](#create-or-switch-to-a-branch)
   - [Stage, Commit, and Push](#stage-commit-and-push)
   - [Useful Inspection Commands](#useful-inspection-commands)
5. [Pull Requests](#pull-requests)
6. [Staying in Sync](#staying-in-sync)
   - [Fetch Latest Changes](#fetch-latest-changes)
   - [Rebase onto Main](#rebase-onto-main)
7. [Pruning Stale Branches](#pruning-stale-branches)
   - [Remove Remote-Tracking References](#remove-remote-tracking-references)
   - [Automate Pruning](#automate-pruning)
   - [Delete Local Branches Gone from Remote](#delete-local-branches-gone-from-remote)
8. [Large Files with Git LFS](#large-files-with-git-lfs)
9. [Housekeeping](#housekeeping)
   - [Rename a Repository](#rename-a-repository)

---

## Initial Setup

Before you can make commits or push code, Git needs to know who you are, and GitHub needs a way to verify it's really you.

### Set Credentials

```sh
git config --global user.email "12345678+username@users.noreply.github.com"
git config --global user.name "username"
```

These values are written to `~/.gitconfig` and embedded into every commit you create as the author identity — they appear in `git log` and on GitHub. Use your GitHub no-reply email (`Settings > Emails`) to keep your personal address private.

### Setup SSH Keys

Check for existing keys first:

```bash
ls -al ~/.ssh
```

Lists the contents of your SSH directory. Look for files like `id_ed25519` and `id_ed25519.pub` — if they exist, you already have a keypair and can skip generation.

Generate a new key:

```bash
ssh-keygen -t ed25519 -C "example@email.com"
```

Creates a keypair using the Ed25519 elliptic-curve algorithm. The private key (`id_ed25519`) stays on your machine and is never shared. The public key (`id_ed25519.pub`) is what you give to GitHub — it can only be used to verify that the private key signed something, not to derive the private key from it. The `-C` comment is just a label so you can tell which device a key came from when reviewing your key list later.

Copy the public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Paste the output into **GitHub > Settings > SSH and GPG keys > New SSH key**.

From now on, when you push or clone over SSH, GitHub challenges your client with a random nonce, your SSH agent signs it with your private key, and GitHub verifies the signature against the stored public key — no password needed.

> When cloning repos, always use the SSH URL (starts with `git@github.com:`) rather than HTTPS.

---

## Creating a Repository

### Initialize Locally

```bash
git init
```

Creates a `.git/` directory inside your current folder. This hidden directory is the entire repository — it stores all commits, branches, config, and history. Your working files sit alongside it; `.git/` is what every `git` command operates on.

### Connect to a Remote

After creating a new repo on GitHub (**GitHub → + → New repository → SSH → Copy URL**):

```bash
git remote add origin <ssh-url>
```

Adds a named pointer called `origin` into `.git/config` that maps to the remote URL. "origin" is a convention, not a requirement — it's just the name Git uses by default for the primary remote.

Verify it was added:

```bash
git remote -v
```

Reads the `[remote "origin"]` block from `.git/config` and prints the registered fetch and push URLs:

```
origin  git@github.com:<owner>/<repo>.git (fetch)
origin  git@github.com:<owner>/<repo>.git (push)
```

---

## Managing Remotes

### Update a Remote URL

If you rename a repo or switch from HTTPS to SSH:

```bash
git remote set-url origin git@github.com:<owner>/<repo>.git
```

Overwrites the URL field in `.git/config` for the `origin` remote. All future fetches and pushes use the new address.

---

## Branching and Daily Workflow

The typical pattern is: create a branch per feature, do your work, then merge it back through a pull request. This keeps `main` stable and lets you isolate changes.

### Create or Switch to a Branch

```bash
git checkout -b feature/feature-name
```

Creates a new branch ref at the current commit (wherever `HEAD` points) and moves `HEAD` to track the new branch. Subsequent commits advance only this branch — `main` stays where it was.

### Stage, Commit, and Push

Check what changed:

```bash
git status
```

Compares your working tree to the index (staging area) and the index to `HEAD`, showing files that are modified, untracked, or already staged.

Stage your changes:

```bash
git add .
```

Copies the current state of all changed files into the index. The index is a snapshot of what your next commit will look like — it's a separate layer between your working files and commit history, giving you the chance to review before committing.

Commit and push:

```bash
git commit -m "Added Feature"
git push origin feature/feature-name
```

`git commit` packages the index into a new commit object — recording the file tree, parent commit hash, author, timestamp, and message — then moves the branch pointer forward to the new commit. `git push` sends those new commit objects to the remote and updates the remote's branch ref to match.

### Useful Inspection Commands

List all local branches:

```bash
git branch
```

Shows every branch ref stored in `.git/refs/heads/`. The current branch is marked with `*`.

Switch to an existing branch:

```bash
git checkout branch-name
```

Moves `HEAD` to point at the named branch and updates your working tree to match that branch's latest commit.

View commit history:

```bash
git log
```

Walks the commit graph backwards from `HEAD`, printing each commit's hash, author, date, and message. Add `--oneline` for a compact view or `--graph` to visualize branch topology.

---

## Pull Requests

Once your branch is pushed, open a pull request on GitHub to propose merging it into `main`.

**GitHub → Compare & Pull Request → Create Pull Request → Review → Merge**

After merging, clean up the branch — the commits now live in `main` and the branch ref is just a stale pointer.

Delete the local branch:

```bash
git branch -d feature/feature-name
```

Deletes only the local branch ref. Because the branch was merged, no commits are orphaned — they remain reachable from `main`. If unmerged work exists, Git refuses with `-d` to protect you (use `-D` to force delete regardless).

Delete the remote branch:

```bash
git push origin --delete feature/feature-name
```

Sends a "delete ref" instruction to the remote, removing the branch there.

Force deletion:

```bash
git branch -D feature/feature-name
```

shorthand for `git branch --delete --force feature/feature/name`

Keep `main` up to date locally:

```bash
git checkout main
git pull origin main
```

Switches `HEAD` to `main`, then fetches new commits from the remote and fast-forwards your local `main` to match — equivalent to `git fetch` followed by `git merge`.

---

## Staying in Sync

### Fetch Latest Changes

```bash
git fetch origin main
```

Downloads commits and refs from the remote into your local repo without touching your working tree or local branches. The remote's state is now reflected in `origin/main` — you can inspect the diff before merging.

### Rebase onto Main

When your feature branch has diverged from `main`, first commit your current work:

```bash
git add .
git commit -m "your commit message"
git push origin your-branch
```

Fetch the latest main:

```bash
git fetch origin main
```

Rebase:

```bash
git rebase origin/main
```

Replays your branch's commits one by one on top of the current tip of `origin/main`, rewriting each commit's parent pointer. The result is a linear history as if you had started your work from the latest `main`. Unlike `git merge`, no merge commit is created.

---

## Pruning Stale Branches

Every time a remote branch is deleted (e.g., after merging a PR), your local repo retains a stale remote-tracking ref like `origin/feature-name`. Over time these pile up and clutter `git branch -a`. Here's how to clean them out.

### Remove Remote-Tracking References

```bash
git fetch --prune
```

Fetches from the remote and then deletes any local remote-tracking refs that no longer exist on the remote. The shorter alias does the same thing:

```bash
git fetch -p
```

If you want to prune without fetching new objects:

```bash
git remote prune origin
```

Same pruning step, but skips downloading new commits — it only removes stale refs for `origin`.

### Automate Pruning

So you never have to think about it again, configure Git to prune automatically on every fetch or pull.

For the current repository only:

```bash
git config remote.origin.prune true
```

For every repository on your machine:

```bash
git config --global fetch.prune true
```

Both write a `prune = true` flag into the relevant `[remote "origin"]` config block. After this, stale remote-tracking refs are removed automatically on every `git fetch` or `git pull`.

### Delete Local Branches Gone from Remote

Pruning removes the `origin/branch-name` tracking refs, but if you ever checked out those branches locally, the local copies still exist. To find and delete them:

```bash
git branch -vv | grep ': gone]' | awk '{print $1}' | xargs git branch -d
```

`git branch -vv` lists each local branch alongside its upstream tracking ref and sync status. Branches whose remote counterpart was deleted show `[origin/branch-name: gone]`. `grep` filters for those lines, `awk` extracts just the branch names, and `xargs git branch -d` deletes them one by one. The `-d` flag is safe — it refuses to delete any branch with unmerged commits. Replace with `-D` only if you're certain you want them gone regardless.

---

## Large Files with Git LFS

Git is optimized for text. Binary files (archives, datasets, build artifacts) bloat the `.git/` directory because every version is stored in full. Git LFS (Large File Storage) solves this by replacing large files in your repo with lightweight pointer files and storing the actual content on a separate LFS server.

Install:

```sh
brew install git-lfs
```

Track a file type:

```sh
git lfs track "*.zip"
git add .gitattributes
```

`git lfs track` writes a filter rule into `.gitattributes`. The rule tells Git to route matching files through the LFS clean/smudge filters on `git add` and `git checkout` respectively — clean converts the file to a pointer on the way in, smudge restores the full file on the way out. Committing `.gitattributes` ensures collaborators get the same tracking rules.

Add and commit as normal:

```sh
git add .
git commit -m "Track zip files with LFS and add a zip file"
```

Find files in your working tree over 10 MB:

```sh
find . -type f -size +10M
```

---

## Housekeeping

### Rename a Repository

1. Rename on GitHub: **Repo → Settings → Repository name → Rename**
2. Rename the local root folder to match.
3. Update the remote URL locally:

```bash
git remote set-url origin git@github.com:<owner>/new-repo-name.git
```

Rewrites the `origin` URL in `.git/config` so future pushes and fetches point to the new address. GitHub redirects old URLs for a while, but updating immediately avoids confusion.
