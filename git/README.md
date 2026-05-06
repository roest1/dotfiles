# GitHub Help

---

### Set Credentials

```sh
git config --global user.email "12345678+username@users.noreply.github.com"
git config --global user.name "username"
```

**Important**:

- Use the email by going to `Settings > Emails` and at the top you'll see your no-reply email.

### Setup SSH Keys

Check for existing keys:

```bash
ls -al ~/.ssh
```

Generate a key:

```bash
ssh-keygen -t ed25519 -C "example@email.com"
```

> As far as the SSH protocol is concerned, the email at the end of the public key is just a comment. It's there so that when you open your authorized_keys file six months from now, you can remember which device that specific key belongs to.

Add key to github:

copy the output of:

```bash
cat ~/.ssh/id_ed25519.pub
```

and paste it into Github Settings > SSH and GPG keys

When cloning repos, make sure to use the ssh link.

### Create/Switch to a new branch

```bash
git checkout -b feature/feature-name
```

You can then edit the files and run git status to see changes made:

```bash
git status
```

Add all changes

```
git add .
git commit -m "Added Feature"
git push origin feature/feature-name
```

### Creating a Pull Request

Github Repo -> Compare & Pull Request -> Create Pull Request -> Review -> Merge to main
After merging, you can delete the feature branch:

```bash
git branch -d feature/feature-name
git push origin --delete feature/feature-name
```

Make sure to keep the main branch up to date:

```bash
git checkout main
git pull origin main
```

---

### Additional Git Commands:

List Branches

```bash
git branch
```

Switch to branch

```bash
git checkout branch-name
```

View commit history

```bash
git log
```

---

# Git LFS

```sh
brew install git-lfs
```

```sh
git lfs track "*.zip"
git add .gitattributes   # Required to commit the tracking config
git add .                # Adds all changes, including your large .zip files
git commit -m "Track zip files with LFS and add a zip file"
```

Show all files in current directory with size > 10MB

```sh
find . -type f -size +10M
```

### Rebase with main branch

commit all changes in your branch first:

```sh
git checkout your-branch
git add .
git commit -m "your commit message"
git push origin your-branch
```

Fetch the latest changes from the main branch

```sh
git fetch origin main
```

Rebase

```sh
git rebase origin/main
```

---

update local view of what exists on GitHub:

```sh
git fetch --prune
```

or equivalently:

```sh
git remote prune origin
```

---

simplest way to delete local branches that are deleted on github

```sh
git fetch -p
git branch -vv | awk '/: gone]/{print $1}' | xargs -r git branch -d
```

---

### Change repo names

1. Change repo name in repo > settings > change repository name
2. Change local root folder name
3. git remote set-url origin https://github.com/roest1/new-repo-name.git
