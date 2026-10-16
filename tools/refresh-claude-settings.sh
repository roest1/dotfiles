#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# Clear the FALSE "modified" on claude/settings.json -- and only when
# it is false.
#
# ── why git reports it at all ───────────────────────────────────────
#
# The clean filter (tools/clean-claude-settings.sh) makes the worktree
# file and its blob legitimately different sizes: this machine's model
# and effort are longer or shorter than the committed defaults. Git's
# ie_modified() short-circuits on a size mismatch and answers "modified"
# WITHOUT re-reading the file, so the filter never runs and `git status`
# reports a change that `git diff` then shows as empty. Measured here:
# worktree 1207 bytes, blob 1197.
#
# No git config reaches this. core.checkStat=minimal drops ctime, ino,
# uid, gid and dev from the comparison and keeps size; --assume-unchanged
# and --skip-worktree do suppress it, but they suppress REAL edits to the
# same file just as silently, and this repo genuinely commits changes to
# settings.json (hooks, permissions). A guard that hides the thing you
# are about to edit is worse than the cosmetic problem it solves.
#
# ── what actually fixes it ──────────────────────────────────────────
#
# `git add` re-records the worktree's stat against the unchanged blob:
# the index then caches size 1207, the short-circuit stops firing, and
# nothing is staged because the filtered content is byte-identical to
# what is already there. It stays clean until the byte count changes
# again, which is the next /model or /effort.
#
# So this runs that `git add` -- after first PROVING it stages nothing.
# The proof is the comparison below, not the claim: filter the worktree
# file and require the result to equal the INDEX blob. If they differ,
# there is a real change in the file and this exits without touching
# anything, because that is a change you are supposed to see.
#
# Index blob rather than HEAD, so a settings change you have already
# staged but not committed is treated as yours and left alone.
#
# Invoked from the SessionStart and SessionEnd hooks in
# claude/settings.json. SessionEnd is the one that does the work, right
# after the only writer stops; SessionStart is the backstop for the
# session that was killed or crashed, where SessionEnd never ran.
#
# Silent and never fatal: it runs on every session on every machine,
# including ones with no clone, no git, or a busy index.lock.
#####################################################################

link="$HOME/.claude/settings.json"

# Not a symlink means this machine does not install [claude] from a clone,
# so there is no index to refresh. Plain `readlink`, not `readlink -f`:
# install.sh writes absolute targets, and -f is GNU-only.
[ -L "$link" ] || exit 0
target=$(readlink "$link") || exit 0
[ -f "$target" ] || exit 0

repo=${target%/*}/..
command -v git >/dev/null 2>&1 || exit 0
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# The path as git knows it, which is what `git add` and `:path` both need.
rel=$(git -C "$repo" ls-files --full-name -- "$target" 2>/dev/null) || exit 0
[ -n "$rel" ] || exit 0

filter="$repo/tools/clean-claude-settings.sh"
[ -x "$filter" ] || exit 0

# The proof below runs the filter by hand, but the `git add` it licenses runs
# whatever filter GIT has -- and filter.* lives in .git/config, written by
# claude/deps.sh. A clone that was only `make link`ed, or not installed yet,
# has none, so the add would store the raw file: this machine's /model,
# staged, by the hook whose job is to keep it out. No filter, no add.
git -C "$repo" config --get filter.claude-settings.clean >/dev/null 2>&1 || exit 0

# A conflicted or otherwise missing stage-0 entry makes this fail, which is
# the correct time to do nothing.
indexed=$(git -C "$repo" cat-file -p ":$rel" 2>/dev/null) || exit 0
filtered=$("$filter" < "$target" 2>/dev/null) || exit 0

# Byte-identical, or there is a real change here and it is not ours to hide.
[ "$filtered" = "$indexed" ] || exit 0

git -C "$repo" add -- "$rel" >/dev/null 2>&1 || exit 0
